// p2perf: cycle-approximate performance model of the p2 SoC (rv32_core +
// RAM + APB peripherals). A functional RV32IM + Zicsr machine-mode model
// (same conventions as model/rv32_iss.py) drives an event-count timing
// model of the 5-stage pipeline:
//   cycles = n_retired + START + 2*taken + 1*load_use + CSR*n_csr
//          + TRAP*n_trap + INTR*n_intr + APB*n_apb + 3*n_mul + 33*n_div
// (taken includes MRET). Time advances per instruction, so mtime polling
// loops spin for the modeled number of cycles.
// The documented costs (taken jump 2, load-use 1, MUL 3, DIV 33: spec 3
// and the CPI test) are fixed; START, CSR, TRAP, INTR and APB are fitted
// against RTL cycle counts by model/perf/calibrate.py and passed in with
// --param NAME=VALUE.
//
// mtime and mcycle advance with the modeled cycle count, so timer
// interrupts land close to (not exactly at) the RTL cycle. The accelerator
// (0x2000_0000) and testbench-driven external interrupts are not modeled.
//
// usage: p2perf [--param NAME=V ...] [--max N] [--json] <program.hex>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

namespace {

constexpr uint32_t kRamSize = 0x10000;
constexpr uint32_t kMisa = 0x40001100;  // RV32, I and M

struct Counts {
  uint64_t retired = 0, taken = 0, load_use = 0, csr = 0, trap = 0, intr = 0, apb = 0,
           mul = 0, div = 0, loads = 0, stores = 0, branches = 0;
};

struct Params {
  double start = 0, csr = 0, trap = 0, intr = 0, apb = 0;
  double taken = 2, load_use = 1, mul = 3, div = 33;
  double uart_div = 868;  // UART divisor after reset (the lockstep bench builds 16)
};

struct TrapEx {
  uint32_t cause, tval;
};

class Model {
 public:
  explicit Model(const Params& p)
      : p_(p), ram_(kRamSize, 0), uart_div_(static_cast<uint32_t>(p.uart_div)) {}

  void load_hex(const std::string& path) {
    std::ifstream f(path);
    if (!f) die("cannot open " + path);
    std::string tok;
    uint32_t addr = 0;
    while (f >> tok) {
      if (tok.rfind("//", 0) == 0) { std::getline(f, tok); continue; }
      if (tok[0] == '@') { addr = std::stoul(tok.substr(1), nullptr, 16); continue; }
      if (addr * 4 + 4 > kRamSize) die(path + ": image larger than RAM");
      uint32_t w = std::stoul(tok, nullptr, 16);
      std::memcpy(&ram_[addr * 4], &w, 4);
      ++addr;
    }
  }

  // Runs to SIMCTRL EXIT; returns false if max_steps was reached first.
  bool run(uint64_t max_steps) {
    for (uint64_t n = 0; n < max_steps && !halted_; ++n) step();
    return halted_;
  }

  double cycles() const { return cyc_; }
  const Counts& counts() const { return c_; }
  int exit_code() const { return exit_code_; }
  const std::string& console() const { return console_; }

 private:
  [[noreturn]] static void die(const std::string& m) {
    std::fprintf(stderr, "p2perf: %s\n", m.c_str());
    std::exit(2);
  }
  static int32_t sext(uint32_t v, int bits) {
    uint32_t m = 1u << (bits - 1);
    v &= (bits == 32) ? 0xFFFFFFFFu : ((1u << bits) - 1);
    return static_cast<int32_t>((v ^ m) - m);
  }
  uint64_t mcycle() const { return mcycle_base_ + static_cast<uint64_t>(cyc_); }
  uint64_t mtime() const { return mtime_base_ + static_cast<uint64_t>(cyc_); }
  uint32_t mip() const { return (mtime() >= mtimecmp_ ? 1u << 7 : 0); }

  uint32_t rd32(uint32_t a) const {
    uint32_t w;
    std::memcpy(&w, &ram_[a & (kRamSize - 4)], 4);
    return w;
  }

  uint32_t bus_read(uint32_t a) {
    if (a >> 28 == 0) return rd32(a);
    if (a >> 28 != 1) return 0;  // accelerator and holes: not modeled, read 0
    ++c_.apb;
    uint32_t dev = (a >> 12) & 0xF, off = a & 0xFFC;
    switch (dev) {
      case 0: return off == 0x4 ? uart_status() : off == 0x8 ? uart_div_ : off == 0xC ? uart_irq_en_ : 0;
      case 1: return off == 0x0 ? gpio_out_ : 0;
      case 2: {
        uint64_t t = mtime();
        return off == 0x0 ? uint32_t(t) : off == 0x4 ? uint32_t(t >> 32)
             : off == 0x8 ? uint32_t(mtimecmp_) : uint32_t(mtimecmp_ >> 32);
      }
      default: return 0;
    }
  }

  void bus_write(uint32_t a, uint32_t d, uint32_t be) {
    uint32_t m = 0;
    for (int i = 0; i < 4; ++i) if (be >> i & 1) m |= 0xFFu << (8 * i);
    if (a >> 28 == 0) {
      uint32_t w = rd32(a);
      w = (w & ~m) | (d & m);
      std::memcpy(&ram_[a & (kRamSize - 4)], &w, 4);
      return;
    }
    if (a >> 28 != 1) return;
    ++c_.apb;
    uint32_t dev = (a >> 12) & 0xF, off = a & 0xFFC;
    auto merge = [&](uint32_t old) { return (old & ~m) | (d & m); };
    if (dev == 0) {
      if (off == 0x0 && (be & 1)) uart_push();
      if (off == 0x8) uart_div_ = merge(uart_div_) & 0xFFFF;
      if (off == 0xC) uart_irq_en_ = merge(uart_irq_en_) & 1;
    } else if (dev == 1) {
      if (off == 0x0) gpio_out_ = merge(gpio_out_) & 0xFFFF;
      if (off == 0x8) gpio_out_ |= d & m & 0xFFFF;
      if (off == 0xC) gpio_out_ &= ~(d & m) & 0xFFFF;
    } else if (dev == 2) {
      uint64_t t = mtime();
      uint32_t lo = uint32_t(t), hi = uint32_t(t >> 32);
      if (off == 0x0) t = (uint64_t(hi) << 32) | merge(lo);
      if (off == 0x4) t = (uint64_t(merge(hi)) << 32) | lo;
      if (off == 0x0 || off == 0x4) mtime_base_ = t - static_cast<uint64_t>(cyc_);
      uint32_t clo = uint32_t(mtimecmp_), chi = uint32_t(mtimecmp_ >> 32);
      if (off == 0x8) mtimecmp_ = (uint64_t(chi) << 32) | merge(clo);
      if (off == 0xC) mtimecmp_ = (uint64_t(merge(chi)) << 32) | clo;
    } else if (dev == 0xF) {
      if (off == 0x0 && be) { exit_code_ = int(d & m); halted_ = true; }
      if (off == 0x4 && (be & 1)) console_ += char(d & 0xFF);
    }
  }

  // UART TX: a 16-entry FIFO feeding a shifter that takes 10 * divisor
  // cycles per byte (spec 8). Each queued byte keeps the cycle it enters the
  // shifter and the cycle it finishes; the FIFO holds bytes not yet started.
  uint32_t uart_bit_cycles() const { return 10 * (uart_div_ < 2 ? 2 : uart_div_); }
  void uart_retire() {
    while (!tx_.empty() && tx_.front().second <= cyc_) tx_.erase(tx_.begin());
  }
  size_t uart_fifo() const {
    size_t n = 0;
    for (auto& b : tx_) n += b.first > cyc_;
    return n;
  }
  void uart_push() {
    uart_retire();
    if (uart_fifo() >= 16) return;  // dropped, as on the RTL
    double start = tx_.empty() ? cyc_ + 1 : std::max(cyc_ + 1, tx_.back().second);
    tx_.push_back({start, start + uart_bit_cycles()});
  }
  uint32_t uart_status() {
    uart_retire();
    size_t n = uart_fifo();
    return (n == 16 ? 1u : 0u) | (tx_.empty() ? 2u : 0u);
  }

  uint32_t csr_read(uint32_t a) {
    switch (a) {
      case 0x300: return (mie_bit_ << 3) | (mpie_ << 7) | (3u << 11);
      case 0x301: return kMisa;
      case 0x304: return mie_;
      case 0x305: return mtvec_;
      case 0x340: return mscratch_;
      case 0x341: return mepc_;
      case 0x342: return mcause_;
      case 0x343: return mtval_;
      case 0x344: return mip();
      case 0xB00: case 0xC00: return uint32_t(mcycle());
      case 0xB80: case 0xC80: return uint32_t(mcycle() >> 32);
      case 0xB02: case 0xC02: return uint32_t(minstret_);
      case 0xB82: case 0xC82: return uint32_t(minstret_ >> 32);
      case 0xF11: case 0xF12: case 0xF13: case 0xF14: return 0;
      default: throw TrapEx{2, 0};
    }
  }

  void csr_write(uint32_t a, uint32_t v) {
    switch (a) {
      case 0x300: mie_bit_ = v >> 3 & 1; mpie_ = v >> 7 & 1; break;
      case 0x304: mie_ = v & 0x880; break;
      case 0x305: mtvec_ = v & ~3u; break;
      case 0x340: mscratch_ = v; break;
      case 0x341: mepc_ = v & ~3u; break;
      case 0x342: mcause_ = v; break;
      case 0x343: mtval_ = v; break;
      case 0xB00: mcycle_base_ = ((mcycle() & ~0xFFFFFFFFull) | v) - uint64_t(cyc_); break;
      case 0xB80: mcycle_base_ = ((uint64_t(v) << 32) | uint32_t(mcycle())) - uint64_t(cyc_); break;
      case 0xB02: minstret_ = (minstret_ & ~0xFFFFFFFFull) | v; cnt_written_ = true; break;
      case 0xB82: minstret_ = (uint64_t(v) << 32) | uint32_t(minstret_); cnt_written_ = true; break;
      default: break;
    }
  }

  void enter_trap(uint32_t cause, uint32_t tval, uint32_t epc) {
    mepc_ = epc & ~3u;
    mcause_ = cause;
    mtval_ = tval;
    mpie_ = mie_bit_;
    mie_bit_ = 0;
  }

  void step() {
    double add = 1;
    const uint64_t apb_before = c_.apb;
    if (mie_bit_ && (mip() & mie_ & 0x80)) {
      enter_trap(0x80000007u, 0, pc_);
      pc_ = mtvec_;
      ++c_.intr;
      add += p_.intr;
      prev_load_rd_ = 0;
    }
    cnt_written_ = false;
    uint32_t pc = pc_, insn = rd32(pc), npc = pc + 4;
    uint32_t op = insn & 0x7F, rd = insn >> 7 & 31, f3 = insn >> 12 & 7, rs1 = insn >> 15 & 31,
             rs2 = insn >> 20 & 31, f7 = insn >> 25;
    int32_t imm_i = sext(insn >> 20, 12);
    bool uses1 = false, uses2 = false, load = false, taken = false, csr = false;
    uint32_t load_rd = 0;
    try {
      auto X = [&](uint32_t r) { return x_[r]; };
      auto jump = [&](uint32_t t) {
        if (t & 3) throw TrapEx{0, t};
        taken = true;
        return t;
      };
      bool wr = true;
      uint32_t res = 0;
      switch (op) {
        case 0x37: res = insn & 0xFFFFF000u; break;
        case 0x17: res = pc + (insn & 0xFFFFF000u); break;
        case 0x6F: {
          int32_t imm = sext(((insn >> 31) << 20) | ((insn >> 12 & 0xFF) << 12) |
                             ((insn >> 20 & 1) << 11) | ((insn >> 21 & 0x3FF) << 1), 21);
          npc = jump(pc + imm);
          res = pc + 4;
          break;
        }
        case 0x67:
          if (f3) throw TrapEx{2, insn};
          uses1 = true;
          npc = jump((X(rs1) + imm_i) & ~1u);
          res = pc + 4;
          break;
        case 0x63: {
          if (f3 == 2 || f3 == 3) throw TrapEx{2, insn};
          uses1 = uses2 = true;
          ++c_.branches;
          uint32_t a = X(rs1), b = X(rs2);
          bool t = f3 == 0 ? a == b : f3 == 1 ? a != b : f3 == 4 ? int32_t(a) < int32_t(b)
                 : f3 == 5 ? int32_t(a) >= int32_t(b) : f3 == 6 ? a < b : a >= b;
          if (t) {
            int32_t imm = sext(((insn >> 31) << 12) | ((insn >> 7 & 1) << 11) |
                               ((insn >> 25 & 0x3F) << 5) | ((insn >> 8 & 0xF) << 1), 13);
            npc = jump(pc + imm);
          }
          wr = false;
          break;
        }
        case 0x03: {
          if (!(f3 == 0 || f3 == 1 || f3 == 2 || f3 == 4 || f3 == 5)) throw TrapEx{2, insn};
          uses1 = true;
          uint32_t a = X(rs1) + imm_i, size = 1u << (f3 & 3);
          if (a & (size - 1)) throw TrapEx{4, a};
          uint32_t v = bus_read(a & ~3u) >> (8 * (a & 3));
          res = f3 == 0 ? uint32_t(sext(v, 8)) : f3 == 1 ? uint32_t(sext(v, 16))
              : f3 == 2 ? v : f3 == 4 ? (v & 0xFF) : (v & 0xFFFF);
          load = true;
          load_rd = rd;
          ++c_.loads;
          break;
        }
        case 0x23: {
          if (f3 > 2) throw TrapEx{2, insn};
          uses1 = uses2 = true;
          int32_t imm = sext(((insn >> 25) << 5) | rd, 12);
          uint32_t a = X(rs1) + imm, size = 1u << f3;
          if (a & (size - 1)) throw TrapEx{6, a};
          uint32_t be = ((1u << size) - 1) << (a & 3);
          bus_write(a & ~3u, X(rs2) << (8 * (a & 3)), be);
          ++c_.stores;
          wr = false;
          break;
        }
        case 0x13: {
          uses1 = true;
          uint32_t a = X(rs1), sh = imm_i & 31;
          if (f3 == 1) {
            if (f7) throw TrapEx{2, insn};
            res = a << sh;
          } else if (f3 == 5) {
            if (f7 == 0) res = a >> sh;
            else if (f7 == 0x20) res = uint32_t(int32_t(a) >> sh);
            else throw TrapEx{2, insn};
          } else {
            res = alu(f3, a, uint32_t(imm_i));
          }
          break;
        }
        case 0x33: {
          uses1 = uses2 = true;
          uint32_t a = X(rs1), b = X(rs2);
          if (f7 == 1) {
            res = muldiv(f3, a, b);
          } else if (f7 == 0x20 && (f3 == 0 || f3 == 5)) {
            res = f3 == 0 ? a - b : uint32_t(int32_t(a) >> (b & 31));
          } else if (f7 == 0) {
            res = f3 == 1 ? a << (b & 31) : f3 == 5 ? a >> (b & 31) : alu(f3, a, b);
          } else {
            throw TrapEx{2, insn};
          }
          break;
        }
        case 0x0F:
          if (f3) throw TrapEx{2, insn};
          wr = false;
          break;
        case 0x73: {
          if (f3 == 0) {
            wr = false;
            if (insn == 0x00000073) throw TrapEx{11, 0};
            if (insn == 0x00100073) throw TrapEx{3, 0};
            if (insn == 0x30200073) {
              npc = mepc_;
              mie_bit_ = mpie_;
              mpie_ = 1;
              taken = true;
            } else if (insn != 0x10500073) {
              throw TrapEx{2, insn};
            }
          } else if (f3 == 4) {
            throw TrapEx{2, insn};
          } else {
            uint32_t a = insn >> 20;
            uint32_t src = f3 < 4 ? X(rs1) : rs1;
            uses1 = f3 < 4;
            bool writes = f3 == 1 || f3 == 5 || rs1 != 0;
            if (writes && a >> 10 == 3) throw TrapEx{2, insn};
            uint32_t old;
            try { old = csr_read(a); } catch (TrapEx&) { throw TrapEx{2, insn}; }
            if (writes) {
              uint32_t nv = (f3 & 3) == 1 ? src : (f3 & 3) == 2 ? (old | src) : (old & ~src);
              csr_write(a, nv);
            }
            res = old;
            csr = true;
          }
          break;
        }
        default:
          throw TrapEx{2, insn};
      }
      if (wr && rd) x_[rd] = res;
      if (!cnt_written_) ++minstret_;
    } catch (TrapEx& t) {
      enter_trap(t.cause, t.tval, pc);
      npc = mtvec_;
      ++c_.trap;
      add += p_.trap;
      load = false;
      taken = false;
      csr = false;
    }
    // Timing events of this instruction.
    if (prev_load_rd_ && ((uses1 && rs1 == prev_load_rd_) || (uses2 && rs2 == prev_load_rd_))) {
      ++c_.load_use;
      add += p_.load_use;
    }
    if (taken) { ++c_.taken; add += p_.taken; }
    if (csr) { ++c_.csr; add += p_.csr; }
    if (op == 0x33 && f7 == 1) {
      if (f3 < 4) { ++c_.mul; add += p_.mul; } else { ++c_.div; add += p_.div; }
    }
    add += p_.apb * double(c_.apb - apb_before);
    prev_load_rd_ = load ? load_rd : 0;
    if (c_.retired == 0) add += p_.start;
    ++c_.retired;
    cyc_ += add;
    pc_ = npc;
  }

  static uint32_t alu(uint32_t f3, uint32_t a, uint32_t b) {
    switch (f3) {
      case 0: return a + b;
      case 2: return int32_t(a) < int32_t(b);
      case 3: return a < b;
      case 4: return a ^ b;
      case 6: return a | b;
      case 7: return a & b;
      default: return 0;
    }
  }

  static uint32_t muldiv(uint32_t f3, uint32_t a, uint32_t b) {
    int64_t sa = int32_t(a), sb = int32_t(b);
    uint64_t ua = a, ub = b;
    switch (f3) {
      case 0: return uint32_t(ua * ub);
      case 1: return uint32_t(uint64_t(sa * sb) >> 32);
      case 2: return uint32_t(uint64_t(sa * int64_t(ub)) >> 32);
      case 3: return uint32_t((ua * ub) >> 32);
      case 4:
        if (b == 0) return 0xFFFFFFFFu;
        if (a == 0x80000000u && b == 0xFFFFFFFFu) return a;
        return uint32_t(int32_t(a) / int32_t(b));
      case 5: return b == 0 ? 0xFFFFFFFFu : a / b;
      case 6:
        if (b == 0) return a;
        if (a == 0x80000000u && b == 0xFFFFFFFFu) return 0;
        return uint32_t(int32_t(a) % int32_t(b));
      default: return b == 0 ? a : a % b;
    }
  }

  Params p_;
  std::vector<uint8_t> ram_;
  uint32_t x_[32] = {};
  uint32_t pc_ = 0;
  uint32_t mie_bit_ = 0, mpie_ = 0, mie_ = 0, mtvec_ = 0, mscratch_ = 0, mepc_ = 0,
           mcause_ = 0, mtval_ = 0;
  uint64_t minstret_ = 0, mcycle_base_ = 0, mtime_base_ = 0, mtimecmp_ = ~0ull;
  uint32_t uart_div_, uart_irq_en_ = 0, gpio_out_ = 0;
  bool halted_ = false, cnt_written_ = false;
  int exit_code_ = -1;
  std::string console_;
  uint32_t prev_load_rd_ = 0;
  double cyc_ = 0;
  std::vector<std::pair<double, double>> tx_;  // UART bytes: (start, finish) cycle
  Counts c_;
};

}  // namespace

int main(int argc, char** argv) {
  Params p;
  uint64_t max_steps = 50'000'000;
  bool json = false;
  std::string prog;
  std::map<std::string, double*> names = {
      {"START", &p.start}, {"CSR", &p.csr}, {"TRAP", &p.trap}, {"INTR", &p.intr},
      {"APB", &p.apb}, {"TAKEN", &p.taken}, {"LOAD_USE", &p.load_use},
      {"MUL", &p.mul}, {"DIV", &p.div}, {"UART_DIV", &p.uart_div}};
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    if (a == "--param" && i + 1 < argc) {
      std::string kv = argv[++i];
      auto eq = kv.find('=');
      auto it = names.find(kv.substr(0, eq));
      if (eq == std::string::npos || it == names.end()) {
        std::fprintf(stderr, "p2perf: bad --param %s\n", kv.c_str());
        return 2;
      }
      *it->second = std::stod(kv.substr(eq + 1));
    } else if (a == "--max" && i + 1 < argc) {
      max_steps = std::stoull(argv[++i]);
    } else if (a == "--json") {
      json = true;
    } else {
      prog = a;
    }
  }
  if (prog.empty()) {
    std::fprintf(stderr, "usage: p2perf [--param NAME=V ...] [--max N] [--json] <program.hex>\n");
    return 2;
  }
  Model m(p);
  m.load_hex(prog);
  bool done = m.run(max_steps);
  const Counts& c = m.counts();
  double cycles = m.cycles();
  if (json) {
    std::printf("{\"exit\": %d, \"done\": %s, \"retired\": %llu, \"cycles\": %.0f, "
                "\"taken\": %llu, \"load_use\": %llu, \"csr\": %llu, \"trap\": %llu, "
                "\"intr\": %llu, \"apb\": %llu, \"mul\": %llu, \"div\": %llu}\n",
                m.exit_code(), done ? "true" : "false", (unsigned long long)c.retired, cycles,
                (unsigned long long)c.taken, (unsigned long long)c.load_use,
                (unsigned long long)c.csr, (unsigned long long)c.trap,
                (unsigned long long)c.intr, (unsigned long long)c.apb,
                (unsigned long long)c.mul, (unsigned long long)c.div);
  } else {
    std::printf("%s: exit %d, %llu instructions, %.0f cycles (CPI %.3f)\n", prog.c_str(),
                m.exit_code(), (unsigned long long)c.retired, cycles,
                cycles / double(c.retired ? c.retired : 1));
    std::printf("  taken %llu, load-use %llu, csr %llu, trap %llu, intr %llu, apb %llu, "
                "mul %llu, div %llu\n",
                (unsigned long long)c.taken, (unsigned long long)c.load_use,
                (unsigned long long)c.csr, (unsigned long long)c.trap,
                (unsigned long long)c.intr, (unsigned long long)c.apb,
                (unsigned long long)c.mul, (unsigned long long)c.div);
  }
  return done ? 0 : 1;
}
