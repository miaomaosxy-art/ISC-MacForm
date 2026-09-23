# Third-party: TI DLP Spectrum Library

## Status

| Item | Value |
|------|-------|
| Official package | TIDCC49 *DLP Spectrum Library Installer v2.0.3* |
| Mac package | TIDCC50 *DLP Spectrum Library Installer for Mac OS v2.0.2* |
| Page | https://www.ti.com/tool/TIDA-00554 |
| Download | https://www.ti.com/tool/download/TIDCC49 · TIDCC50 |
| License | TI license — **do not commit restricted TI source to a public repo** |

TIDCC49 / TIDCC50 downloads are gated by **TI export approval** (login + click-through).
They cannot be fetched anonymously from CI.

## What lives here

| Path | Contents | License |
|------|----------|---------|
| `DLPSpectrumLibrary/` | **You place official TI C sources here** (`dlpspec*.c/h`, `tpl.c/h`, …) | TI |
| `DLPSpectrumLibrary/build/` | Local build outputs (`libdlpspec.a/.dylib`) | build artifacts |
| `vendor-objects/` | `dlpspec*.o` + `tpl.o` extracted from the vendor EasyNIR static library in `二次开发资料SDK` (x86-64 ELF, **not linkable on macOS arm64**) | vendor SDK, for type recovery / reference only |
| `../Sources/CDLPSpec/include/` | Type layouts recovered from vendor DWARF (`scanResults`, `calibCoeffs`, API signatures) | derived from vendor library debug info |

## How to install TI source

1. Open https://www.ti.com/tool/download/TIDCC49 (or TIDCC50).
2. Sign in and complete export approval.
3. Unzip the installer / library package.
4. Copy C sources into `third_party/DLPSpectrumLibrary/` so that these files are findable:
   - `dlpspec.c`, `dlpspec_scan.c`, `dlpspec_calib.c`, `dlpspec_util.c`
   - `dlpspec_scan_col.c`, `dlpspec_scan_had.c`, `dlpspec_helper.c`
   - `tpl.c` and matching headers
5. Run:

```bash
./scripts/build-dlpspec.sh
./scripts/build-interpret-tool.sh
./build/interpret_scan scan_complete.bin scan.csv
```

## Do not

- Reimplement `dlpspec_scan_interpret`.
- Commit TI source to a public GitHub repository without checking the TI license.
- Invent wavelength/intensity if interpret fails — report the error code and raw size instead.
