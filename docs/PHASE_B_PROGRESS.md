# Phase B Progress: Move L2+L3 to ADRV Board

**Goal:** Run OAI's L2 (MAC/RLC) + L3 (PDCP/RRC) on the ADRV9361-Z7035's Cortex-A9, with L1 (PHY) staying on the Jetson. The board already runs Ella Core (5GC). All three layers + 5GC on one Cortex-A9, with the Jetson reduced to the radio-facing PHY only.

The split point is **FAPI** (Small Cell Forum 222.10), tunneled over IP as **nFAPI**. OAI's `nr-softmodem` is the same binary in both roles, with `--nfapi VNF` (L2+) and `--nfapi PNF` (L1) flags.

## Status

| Task | State |
|---|---|
| Real-time-friendly kernel | ✅ Built, deployed, measured |
| Cyclictest scheduling baseline | ✅ 41 µs idle, 69 µs under load w/ pinning |
| OAI cross-compile for armv7 | ✅ `nr-softmodem` (17 MB stripped) + rfsim/libconfig |
| VNF config (board) | ⏳ Next |
| PNF config (Jetson) | ⏳ Next |
| nFAPI handshake | ⏳ Next |
| End-to-end UE attach via split | ⏳ Next |
| Throughput vs Phase A | ⏳ Next |

## RT-ish Kernel

PREEMPT_RT is mainlined in 6.12+. Our base (ADI's `analogdevicesinc/linux` 2023_r2 → kernel 6.1.70) doesn't have `ARCH_SUPPORTS_RT` set on ARM, so full RT isn't available without porting the rt-stable patch series. We took the standard "preemptible + tickless + isolated CPU + SCHED_FIFO" approach instead, which is what most OAI deployments use anyway.

### Changes applied to the previous Phase A kernel config
- `CONFIG_HZ_100` → `CONFIG_HZ_1000` (1 ms scheduling granularity, vs 10 ms)
- `CONFIG_HZ_PERIODIC` → `CONFIG_NO_HZ_FULL=y` + `CONFIG_NO_HZ_COMMON=y` (tickless isolated cores)
- `CONFIG_RCU_NOCB_CPU=y` (move RCU callbacks off isolated cores)
- `CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y` (avoid scaling jitter)
- Added `dwarves` package at build host so `CONFIG_DEBUG_INFO_BTF=y` actually generates BTF this time (the Phase A kernel set it but pahole was missing, so BTF was silently not produced).

Boot args for production use:
```
isolcpus=1 nohz_full=1 rcu_nocbs=1
```
Not yet set in `uEnv.txt` since the cyclictest results without it were already within budget for our use case.

### Cyclictest measurements (10 s, 10000 samples, SCHED_FIFO prio 80, 1 ms interval)

| Scenario | Max latency |
|---|---|
| Idle, no pinning | **41 µs** |
| `stress -c 2 -m 1 --vm-bytes 128M`, no pinning | 470 µs |
| Same stress, cyclictest pinned to CPU 1 via `taskset -c 1` | **69 µs** |

For nFAPI's 1 ms TTI at 15 kHz SCS, 69 µs spike under load eats ~7% of the budget per side — well within margin. With `isolcpus=1` on the boot args we'd expect to get back to near 41 µs even under load.

## OAI armhf Cross-Compile

### Approach

OAI's official `cross-arm.cmake` is for aarch64. I copied the pattern into `cmake_targets/armhf-toolchain.cmake` with one important fix: `set(CMAKE_LIBRARY_ARCHITECTURE arm-linux-gnueabihf)`. Without this, `find_library` doesn't search `/usr/lib/arm-linux-gnueabihf/` even with `CMAKE_FIND_ROOT_PATH` set, and packages like libsctp can't be found despite being installed.

The two-stage build pattern from the OAI docs is critical: OAI uses **code generators** (`bnProc_gen_128`, `bnProc_gen_avx2`, `cnProc_gen_128`, etc.) that *run at build time* to emit C source code for the LDPC encoder/decoder. These must be built for the build host (aarch64), not the target. Stage 1 builds them natively for aarch64; stage 2 cross-compiles for armhf, pointing at the stage 1 output via `-DNATIVE_DIR=...`.

CMake flags that mattered:
- `-DCROSS_COMPILE=ON` — tells `CMakeLists.txt` to skip host CPU autodetection (which otherwise injects `-march=native`, fatal for ARM)
- `-DAVX2=OFF -DAVX512=OFF` — disable x86 SIMD code generators that don't make sense on ARM

### Patches needed (4 files)

The cross-compile got 10500/10505 files compiled before stopping. Four PHY files use x86-only intrinsics with no armv7 path in OAI:

#### `nrLDPC_coding_segment_encoder.c` — extended NEON branch to armv7
The existing `__aarch64__` branch uses `vaddv_u8` (across-vector reduce) which only exists in aarch64 NEON. Added a `VADDV_U8` macro that uses `vpaddl_u8` → `vpaddl_u16` → `vget_lane_u32` for armv7. Real NEON code path, no semantic change.

#### `nr_modulation.c` (`cmac0_prec128`) — `vuzpq_s16` shim
The aarch64 branch uses `vuzp1q_s16`/`vuzp2q_s16` (even/odd lane deinterleave, aarch64 only). On armv7, `vuzpq_s16(a, a)` returns a struct `int16x8x2_t` with `.val[0]` and `.val[1]`. Added an `#ifdef __aarch64__` to pick the right path. Also extended the precoder call sites (line 969) to dispatch to the int16x8_t code on armv7.

#### `nr_polar_encoder.c` — `__uint128_t` polyfill + stub
GCC's `__uint128_t` only exists on 64-bit platforms. Two functions use it:

1. `polar_rate_matching` — fully wrapped in `#if defined(__SIZEOF_INT128__)` with an `AssertFatal` stub on 32-bit. VNF never executes this; it's L1 polar rate matching for PBCH/DCI/UCI.
2. `polar_encoder_fast` (bitlen ≤ 128 path) — only that single branch wrapped, rest of the function still works on armv7 with uint64_t inputs.
3. `build_polar_tables` — this *is* called during VNF setup. Rewrote the inner loop to use two `uint64_t` pieces directly instead of a `union { uint128_t; uint64_t[2]; }`. Same semantics, no SIMD needed, works everywhere.

`nr_polar_defs.h` polyfills `uint128_t` as `struct { uint64_t lo; uint64_t hi; }` on 32-bit so the type exists for declarations but won't accidentally produce silent truncation.

#### `nr_ulsch_demodulation.c` (`nr_ulsch_comp_muli_sum`, `nr_ulsch_mmse_2layers`) — armv7 stub
Uses `simde_mm_slli_epi32(v, var)` where `var` is a non-constant. SIMDE maps this to `vshlq_n_s32` on armv7 which requires a compile-time immediate. Both functions are L1 uplink equalization, not called by VNF. Stubbed with `AssertFatal` on `__arm__ && !__aarch64__`.

### Other gotchas hit

- `cannot find -lz` at link time — `zlib1g-dev:armhf` not installed by default. Trivial fix.
- `Findsctp.cmake` finds the library only with `CMAKE_LIBRARY_ARCHITECTURE` set (see toolchain note).

### Build artifacts

```
nr-softmodem (stripped)      17 MB   ARM EABI5 32-bit, dynamically linked
librfsimulator.so            1.2 MB
libparams_libconfig.so       105 KB
```

All from `cmake_targets/ran_build/build_armhf/` after `build-oai-armhf.sh`.

### Reproducibility

- `sd-card/build-oai-armhf.sh` — two-stage build wrapper, idempotent (stage 1 cached)
- `patches/oai-armhf.patch` — apply against a fresh OAI tree before building

## What's Next

1. Write VNF config (`gnb-vnf.sa.band78.106prb.nfapi.conf`-style) targeting the board's IP
2. Write PNF config with rfsim radio targeting the Jetson, pointing at board's VNF IP
3. Deploy `nr-softmodem` + libs to `/opt/oai/` on board, write a systemd unit
4. Start VNF on board, PNF on Jetson, nrUE on Jetson — measure attach time
5. Compare against Phase A: throughput, latency, CPU usage on board
