# rtl/accel/p1: attention engine from p1-attention (copied, not edited)

Source: p1-attention commit `86d497c56a39a8364c21f87758da95bae349f767`
(`git -C ../p1-attention rev-parse HEAD`, 2026-11-08), files from
its `rtl/` directory, byte-identical:

| File | sha256 |
|---|---|
| mac_unit.sv | 695c938d0c23614cc2c83dace6937a0af916c998410bbfdd29787360f42bc2a4 |
| matmul_tile.sv | d18636665d8db38b824784837e2bb7b4e782c7a9dfe684466a61ed5e2415c216 |
| exp_lut_1p.sv | b00e27937ef3a271d79ea29f032764071957413c71c9f2cc19e62ea67e31be35 |
| sync_ram.sv | 3cd6c13dedfd15f4c879733a7a7d32c8667b08f4995373bb3cabf3fb6edde73a |
| online_softmax.sv | 12806992436c4c48371a6c5969d21fa595ab64f6df39c471afb2db6005287d6f |
| attention_top.sv | 3a27aad4d2414a31bef177279bad31d2c64834e5d11d810d5656de4c2ffc863d |
| rtl/exp_lut.svh | 8dfdc996b5710ff07029e22c438d8a8729cc353354693e2c5de5f0cdbf8fc835 |

`online_softmax.sv` and `exp_lut_1p.sv` say `` `include "rtl/exp_lut.svh" ``
(a path relative to p1's repo root). The header is therefore kept at
`rtl/accel/p1/rtl/exp_lut.svh` and every tool is given
`+incdir+rtl/accel/p1` (Verilator, Yosys `-I`), so the files need no edit.

Do not edit these files here. To update, copy from a newer p1 commit,
update this table, and rerun `make -C tb/accel` (its `test_p1_copy`
check compares every file against p1 at the commit above).
