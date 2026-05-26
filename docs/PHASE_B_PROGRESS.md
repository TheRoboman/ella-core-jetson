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

## Deployment Progress

Configs created (`configs/`):
- `gnb-vnf-adrv.conf`  — board-side VNF (L2+L3), adapted from
  `gnb-vnf.sa.band78.106prb.nfapi.conf`. Only IP-address fields changed:
  AMF and gNB IPs set to `169.254.237.42` (board), nFAPI south side
  set to `169.254.237.1` (Jetson PNF).
- `gnb-pnf-jetson.conf` — Jetson-side PNF (L1), adapted from
  `gnb-pnf.band78.rfsim.conf`. nFAPI north side set to the board IP.

Binary + runtime libs deployed to board at `/opt/oai/` (17 MB
`nr-softmodem`, plus `libldpc.so`, `librfsimulator.so`, etc.).
Required armhf runtime packages installed by side-loading via the
Jetson: `libsctp1`, `libconfig9`, `libssl3`, `libblas3`, `liblapack3`,
`liblapacke`, `libfftw3-{double,single}3`, `libnuma1`, `libcap2`,
`libatomic1`, `libgfortran5`, `zlib1g`.

### Runtime fix: cycle counter is privileged on Cortex-A9

First run on the board exited with SIGILL. Faulting instruction (found
via core dump + addr2line):

```
mrc p15, 0, r5, c9, c13, 0   // PMCCNTR — privileged in user mode
```

Source: `common/utils/time_meas.h`'s `__arm__` branch of `rdtsc_oai()`.
On x86 OAI uses `rdtsc` (unprivileged); on aarch64 it uses `cntvct_el0`
(also unprivileged). The armhf path went straight to PMCCNTR via CP15
which requires kernel cooperation (setting `PMUSERENR.EN`) — by default
SIGILL in user mode on ARMv7.

Patch: replace the armhf `rdtsc_oai` with `clock_gettime(CLOCK_MONOTONIC)`.
On Linux this is a VDSO call (no syscall overhead) and the result is in
nanoseconds. `get_cpu_freq_GHz()` will then return ~1.0 (1 GHz "tick"
equivalent) because diff over a 1s sleep is ~1e9.

### Current blocker: 32-bit ABI mismatch in OAI config system

Root-caused by bisecting with `fprintf` debug:

1. `prepare_scc()` correctly allocates `scc->...->scs_SpecificCarrierList`
   and calls `asn1cSeqAdd()` to insert one element. State at exit:
   `array=0x28cdbb8 count=1 size=4` — valid.

2. `GET_PARAMS(SCCsParams, SCCPARAMS_DESC(scc), aprefix)` (line 970 of
   `gnb_config.c`) **clobbers** `scs_SpecificCarrierList.list.array` to
   `NULL` while leaving `.count = 1`. The subsequent
   `array[0]->carrierBandwidth` deref segfaults at line ~1023.

3. Root cause: `SCCPARAMS_DESC` uses `TYPE_INT64` (with `.i64ptr` and
   `.defint64val`) for fields whose ASN.1-generated target type is
   `long *`:

   ```c
   {"dl_carrierBandwidth", NULL, 0,
    .i64ptr = &scc->...->scs_SpecificCarrierList.list.array[0]->carrierBandwidth,
    .defint64val = 217, TYPE_INT64, 0}
   ```

   The libconfig handler writes 8 bytes:
   ```c
   *(cfgoptions[i].u64ptr) = (uint64_t)llu;
   ```

   On x86_64 / aarch64: `sizeof(long) == 8` → write fits the target.
   On armv7 (armhf): `sizeof(long) == 4` → 4 bytes overflow into the
   next heap allocation. Adjacent allocations corrupt various pointer
   fields, including `scs_SpecificCarrierList.list.array`.

4. Attempted workaround: snapshot the affected list `array`/`size`
   fields before GET_PARAMS, restore them after. Did not fix the crash
   because GET_PARAMS performs many such 4-byte overflows; corruption
   spreads to other adjacent fields that we did not snapshot.

### Fix: introduce TYPE_LONG in OAI's config system

Implemented across the config layer:

- `common/config/config_paramdesc.h`: added `.lptr` / `.ulptr` to the
  value-pointer union (`long *`), `.deflongval` to the default union,
  and `TYPE_LONG = 11` / `TYPE_ULONG = 12` enum values.
- `common/config/libconfig/config_libconfig.c`: added read+write cases
  for TYPE_LONG that use `sizeof(long)` byte writes through `.lptr`.
- `common/config/config_cmdline.c`: TYPE_LONG cmdline parser.
- `common/config/config_common.c/.h`: `config_setdefault_long()` for
  default values.
- `common/config/config_load_configmodule.c`: dispatch case.
- `common/config/yaml/config_yaml.cpp`: yaml read case.

Then converted `SCCPARAMS_DESC`, `SCC_PATTERN2_PARAMS_DESC`, and
`MSGASCCPARAMS_DESC` (in `RRC_nr_paramsvalues.h`) from `TYPE_INT64` /
`.i64ptr` / `.defint64val` to `TYPE_LONG` / `.lptr=(long*)…` /
`.deflongval`. Mechanical sed-like change preserving target pointers.

### Result so far

The SCC crash at line ~1023 (`array[0]->carrierBandwidth` deref) is
gone — VNF startup progresses past `get_scc_config()`.

But: `RCconfig_nr_macrlc` SIGSEGVs **later** in its execution at a
different offset, with the same NULL-deref-via-offset-40 pattern.
That means there are MORE descriptors elsewhere with the same
`TYPE_INT64` → `long *` bug. Candidates from the call site list:
`GNBPARAMS_DESC`, `MACRLCPARAMS_DESC`, `RUPARAMS_DESC`,
`GNB_TIMERS_PARAMS_DESC`, plus any further-nested descriptors
RCconfig_nr_macrlc uses.

### Result of the TYPE_LONG conversion

After patching all four libconfig/cmdline/yaml/load_configmodule paths
plus the SCC family of macros, the VNF binary now:

1. ✅ Passes prepare_scc/prepare_msgA_scc
2. ✅ Passes both GET_PARAMS_LIST(SCC, MsgA) calls (no corruption)
3. ✅ Successfully reads ServingCellConfigCommon and logs:
   `[RRC] Read in ServingCellConfigCommon (PhysCellId 1, ABSFREQSSB 641280, DLBand 78, ABSFREQPOINTA 640008, DLBW 106, RACH_TargetReceivedPower -96)`
4. ✅ Configures TDD pattern (5 ms total, 8 DL slots, 3 UL slots)
5. ✅ Sets MIB encoding, PUSCH/PUCCH targets, antenna config
6. ✅ Logs all 10 TDD slot configurations (slots 0-9 DOWNLINK/UPLINK/FLEXIBLE)
7. ❌ SIGSEGVs immediately after — inside libc (PC 0xb69dac6e in
   `/usr/lib/arm-linux-gnueabihf/libc.so.6`), unwind shows corrupt stack.

The crash is no longer in our descriptor code at all. It's now in libc
called from somewhere in the MAC/PHY init that runs after
`set_tdd_config_nr()`. Likely candidates:
- `init_DL_MIMO_codebook()` (line 709 in `openair2/LAYER2/NR_MAC_gNB/config.c`)
- The `if (IS_SA_MODE(get_softmodem_params()))` block that reads
  `frequencyInfoDL->scs_SpecificCarrierList.list.array[0]->carrierBandwidth`
  (line 728)
- A printf/snprintf with a bad format that the corrupted stack
  doesn't even survive

The corrupt-stack signature suggests a buffer-overflow that overwrote
the return address before libc's frame, OR a printf format mismatch
(e.g. `%lld` against `long` on armhf prints garbage AND consumes
8 bytes from varargs which slides everything below).

### Other ABI hazards found (none currently blocking)

While scanning the codebase:
- `time_meas.h` armhf `rdtsc_oai` used privileged CP15 instruction
  → fixed by switching to `clock_gettime(CLOCK_MONOTONIC)`
- `nr_modulation.c:281` uses `vqtbl1q_u8` (aarch64-only) but is
  properly gated by `#if defined(__aarch64__) && defined(USE_NEON)`
  → no fix needed
- 22 `.i64ptr=` entries in `sl_preconfig_paramvalues.h` (UE-side
  sidelink) target ASN.1 `long *` but are not in the VNF path
- 11 TYPE_INT64 entries in `gnb_paramdef.h` use `.i64ptr=NULL` (set
  at runtime). Inspection shows they store native int64 values
  parsed from config (no ASN.1 target), so they're correct as-is.

### Conclusion

The TYPE_LONG fix and SCCPARAMS_DESC conversion brought us from
"crash at config parse" all the way through to "crash in libc during
PHY init" — meaningful progress. The remaining crash is not in our
descriptor system and needs separate investigation (likely a printf
format mismatch or another L1-side intrinsic issue we haven't found).

## What's Next

1. ⏳ Resolve `get_scc_config` NULL-deref (only blocker left)
2. Configure systemd unit on board for `nr-softmodem --nfapi VNF`
3. Configure PNF on Jetson, point at board, attempt nFAPI handshake
4. Full UE attach via the split, compare metrics vs Phase A
