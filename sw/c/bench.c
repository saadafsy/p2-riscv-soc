// Benchmark: CRC-32 (reflected, poly 0xEDB88320) over 4 KB of xorshift32 data and an
// 8x8 int32 matrix multiply, checked against known results; reports mcycle/minstret.
#include "printf.h"
#include "soc.h"

#define N_BYTES 4096
#define CRC_CHECK 0xCBF43926u     // CRC-32("123456789")
#define CRC_EXPECT 0x614183EEu    // CRC-32 of the xorshift32 buffer (scripts/bench_ref.py)
#define MAT_EXPECT 0x00082100u    // checksum of A*B (scripts/bench_ref.py)
#define M 8

static uint8_t buf[N_BYTES];
static int32_t A[M][M], B[M][M], C[M][M];

static uint32_t crc32(const uint8_t *p, uint32_t n) {
  uint32_t crc = 0xFFFFFFFFu;
  while (n--) {
    crc ^= *p++;
    for (int k = 0; k < 8; k++) crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
  }
  return ~crc;
}

static uint32_t matmul_checksum(void) {
  for (int i = 0; i < M; i++)
    for (int j = 0; j < M; j++) {
      A[i][j] = i * M + j - 20;
      B[i][j] = (i - j) * 3 + 1;
    }
  for (int i = 0; i < M; i++)
    for (int j = 0; j < M; j++) {
      int32_t s = 0;
      for (int k = 0; k < M; k++) s += A[i][k] * B[k][j];
      C[i][j] = s;
    }
  uint32_t sum = 0;
  for (int i = 0; i < M; i++)
    for (int j = 0; j < M; j++) sum += (uint32_t)C[i][j] * (uint32_t)(i * M + j + 1);
  return sum;
}

int main(void) {
  static const uint8_t check[] = "123456789";
  uint32_t x = 0x12345678u;
  for (int i = 0; i < N_BYTES; i++) {
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    buf[i] = (uint8_t)x;
  }
  uint32_t c0 = csr_read(mcycle), i0 = csr_read(minstret);
  uint32_t crc_check = crc32(check, 9);
  uint32_t crc = crc32(buf, N_BYTES);
  uint32_t mat = matmul_checksum();
  uint32_t c1 = csr_read(mcycle), i1 = csr_read(minstret);
  printf("crc32(check)=%08x crc32(buf)=%08x matmul=%08x\n", crc_check, crc, mat);
  printf("mcycle=%u minstret=%u\n", c1 - c0, i1 - i0);
  int fails = (crc_check != CRC_CHECK) + (crc != CRC_EXPECT) * 2 + (mat != MAT_EXPECT) * 4;
  printf(fails ? "bench: FAIL %d\n" : "bench: PASS\n", fails);
  return fails;
}
