# Patches

## `oai-armhf.patch`

Complete set of OAI changes needed to build and run OAI on armv7 (Cortex-A9)
alongside the Ella Core 5GC. Applies cleanly on top of OAI commit
`7fa4d018d4178f9664ea1ca377eca2e822c7a979` (~2026.w07).

Touches 27 files; `oai-armhf.files` lists them.

Categories of fix:

| Category | Files |
|---|---|
| Cross-compile toolchain | `cmake_targets/armhf-toolchain.cmake` |
| TYPE_LONG config-descriptor type (heap-corruption fix for SCC) | `common/config/config_cmdline.c`, `config_common.{c,h}`, `config_load_configmodule.c`, `config_paramdesc.h`, `libconfig/config_libconfig.c`, `yaml/config_yaml.cpp` |
| armv7-safe ABI shims | `common/utils/time_meas.h` (CP15 PMU → CLOCK_MONOTONIC), `openair1/PHY/CODING/nrPolar_tools/nr_polar_defs.h` (uint128_t polyfill), `openair1/PHY/CODING/nrPolar_tools/nr_polar_encoder.c`, `openair1/PHY/MODULATION/nr_modulation.c`, `openair1/PHY/CODING/nrLDPC_coding/nrLDPC_coding_segment/nrLDPC_coding_segment_encoder.c`, `openair1/PHY/NR_TRANSPORT/nr_ulsch_demodulation.c` |
| Non-fatal thread name | `common/utils/system.c` |
| nFAPI VNF phy_id allocation (idempotent + single-phy) | `nfapi/oai_integration/nfapi_vnf.c` |
| RRC/MAC printf format specifiers (`%lu`/`%ld` → `PRIu64`/`PRId64` for `uint64_t` fields) | `openair2/LAYER2/NR_MAC_gNB/config.c`, `nr_radio_config.c`, `openair2/RRC/NR/rrc_gNB_du.c`, `openair2/GNB_APP/gnb_config.c` |
| `(1l << 36)` shift overflow on armhf | `openair2/LAYER2/NR_MAC_gNB/nr_radio_config.c` |
| TYPE_LONG conversions in SCC param descriptors | `openair2/GNB_APP/RRC_nr_paramsvalues.h` |
| NGAP `asn_INTEGER2ulong` → `asn_INTEGER2uint64` for `AMF_UE_NGAP_ID` + UE AMBR (was writing 4 bytes into a 64-bit local on armhf) | `openair3/NGAP/ngap_common.c`, `ngap_gNB_handlers.c`, `ngap_gNB_mobility_management.c`, `ngap_gNB_nas_procedures.c`, `ngap_gNB_encoder.c` (debug print) |
| Debug aid for ULSCH null harq_process | `openair1/SCHED_NR/phy_procedures_nr_gNB.c` |

To apply:

```bash
cd ~/openairinterface5g
git checkout 7fa4d018d4178f9664ea1ca377eca2e822c7a979
git apply ~/ella-core-jetson/patches/oai-armhf.patch
```

Build for armhf with:

```bash
cd cmake_targets/ran_build
mkdir -p build_armhf && cd build_armhf
cmake .. -DCMAKE_TOOLCHAIN_FILE=../../armhf-toolchain.cmake -DCROSS_COMPILE=ON
ninja nr-softmodem
```

## `userspace-upf-and-armv7.patch`

Patches Ella Core (https://github.com/ellanetworks/core) to fall back to a
userspace GTP-U forwarder on kernels that don't support the eBPF/XDP UPF
(< 6.8), plus armv7 build/int-width fixes. Applies on top of Ella v1.10.2.

## `gtpu_forwarder.go`

New file added to Ella Core at `internal/upf/gtpu_forwarder.go` — implements
the userspace GTP-U forwarder used by the patch above.
