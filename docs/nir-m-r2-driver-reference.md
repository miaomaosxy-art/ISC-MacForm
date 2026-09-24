# NIR-M-R2 Driver Reference

Verified USB Host / protocol / scan reference for ESP32-S3 and other hosts.
Only **live-verified** behavior on **NIR-M-R2** is recorded here.
Values marked "tested configuration only" must not be hardcoded for other devices.

Reference implementation: this repository (`nir-m-r2-macos`).

---

## USB Identity

| Field | Value |
|-------|-------|
| Vendor ID | `0x0451` |
| Product ID | `0x4200` |
| Class | USB HID |
| Application packet | **64 bytes**, **no Report ID** |
| Manufacturer (string) | `Inno-Spectra Corp.` |
| Product (string) | `NIR-M-R2` |

Enumeration filter: match VID/PID, then open the HID interface.
Live path on macOS: `DevSrvsID:…` (hidapi).

---

## Packet layout (application payload)

Little-endian multi-byte fields.

```text
Byte 0   ID          (0x00 protocol id on TX)
Byte 1   Flags
Byte 2   Sequence
Byte 3   Length LSB  (payload+command+group length)
Byte 4   Length MSB
Byte 5   Command
Byte 6   Group
Byte 7…  Payload
```

### Flags (byte 1)

| Bit / value | Meaning |
|-------------|---------|
| `0x80` | Read |
| `0x00` | Write |
| `0x40` | Reply / Ready |
| `0x00` | Error success |
| `0x10` | Error |
| `0x20` | Busy |

Typical TX flags: read request `0x80`, write request `0x00`.
Typical RX flags: read reply `0xC0`, write reply `0x40`.

### USB report note (important)

Live NIR-M-R2 uses **compact 64-byte reports**:
- Host writes 64 bytes (no Report ID prefix).
- Some reads may appear as 65 bytes with a leading `0x00` report-id on certain stacks — strip it if present.
- `FILE_GET_DATA` first report of each logical chunk uses a **4-byte compact header**:
  `flags, seq, length_lsb, length_msb`, then data. Continuation reports are mostly raw body.

Do not assume every response echoes Command/Group. Sequence is validated when non-zero.

---

## Command groups

| Group | Value |
|-------|-------|
| File | `0x00` |
| Factory | `0x01` |
| System | `0x02` |
| Sensor | `0x03` |
| Status | `0x04` |

### Commands used on the verified path

| Command | Group | Code | Purpose |
|---------|-------|------|---------|
| `FILE_GET_READSIZE` | `0x00` | `0x2D` | File size for type |
| `FILE_GET_DATA` | `0x00` | `0x2E` | Next file chunk |
| `PERFORM_SCAN` | `0x02` | `0x18` | Start scan (payload = flag) |
| `SCAN_GET_STATUS` | `0x02` | `0x19` | 0 = in progress, 1 = complete |
| `READ_SCAN_TIME` | `0x02` | `0x37` | Estimated scan time (ms, u32) |
| `SCAN_CFG_NUM` | `0x02` | `0x22` | Number of scan configs (u8) |
| `SCAN_GET_ACT_CFG` | `0x02` | `0x23` | Active config index (u8) |
| `TIVA_VERSION` | `0x02` | `0x16` | 7 × u32 versions |
| `SERIAL_NUMBER_READ` | `0x02` | `0x33` | 8-byte ASCII serial |
| `GET_BOARD_LEVEL` | `0x03` | `0xFE` | HW version + ADC |
| `READ_MODEL_NAME` | `0x03` | `0xFD` | 16-byte model name |
| `READ_DEVICE_STATUS` | `0x04` | `0x03` | u32 status bits |

### PERFORM_SCAN flag

| Value | Meaning (live-verified) |
|-------|-------------------------|
| `0x00` | **Complete scan data** (primary path) |
| `0x5A` | Simplex scan data (device-interpreted; empty on Tiva 2.6.3) |

### File types

| Type | Code | Use |
|------|------|-----|
| `NNO_FILE_SCAN_DATA` | `0x00` | Serialized complete scan (feed to `dlpspec_scan_interpret`) |
| `NNO_FILE_SCAN_CONFIG` | `0x01` | Scan config blob |
| `NNO_FILE_REF_CAL_DATA` | `0x02` | Factory serialized reference scan, read only |
| `NNO_FILE_REF_CAL_MATRIX` | `0x03` | Factory interpolation matrix, read only |
| Simplex wavelength | `0x0C` | Empty on this firmware |
| Simplex intensity | `0x0D` | Empty on this firmware |

---

## FILE_GET_DATA — multi-chunk (critical)

```text
FILE_GET_READSIZE(type)  →  u32 expected_bytes
loop:
    FILE_GET_DATA         →  one logical chunk
    append chunk
until received >= expected_bytes
truncate to expected_bytes
```

**Finding (verified on live USB):**

> `FILE_GET_DATA` MUST be issued repeatedly.
> Do **not** assume one command returns the entire file.
>
> Each `FILE_GET_DATA` returns one logical chunk (often ~512 bytes of payload length),
> itself fragmented across 64-byte HID reports. Send `FILE_GET_DATA` again for the next chunk.

If the loop stops early, treat as **FILE_GET_DATA truncated** and fail the scan
(keep raw partial bytes for diagnostics if needed).

---

## Verified complete scan flow

```text
Open HID (VID 0x0451 / PID 0x4200)
    ↓
READ_SCAN_TIME                 (optional budget hint)
    ↓
PERFORM_SCAN (flag 0x00)
    ↓
poll SCAN_GET_STATUS until 1   (100 ms interval; timeout ≈ estimated + 5 s)
    ↓
FILE_GET_READSIZE (0x00)       expect 3822 B on Hadamard 1 / C36R011
    ↓
repeated FILE_GET_DATA
    ↓
3822-byte complete scan blob
    ↓
dlpspec_scan_interpret()       (DLP Spectrum Library 2.0.3)
    ↓
wavelength[] + intensity[]     (228 points on this config)
```

USB commands are **serialized**. Never overlap command/response pairs on one device.

---

## Reference Architecture

The [official Windows `ISC-NIRScan-GUI` distribution](https://github.com/InnoSpectra/ISC-NIRScan-GUI)
and its `isccpp.dll` call chain use three modes:

| Mode | Source | Device writes |
|------|--------|---------------|
| Built-In (`0`) | `SPEC_FetchRefCalData` from device | None |
| Previous (`1`) | Previously scanned white reference on host | None |
| New (`2`) | One normal complete scan of a physical white target, saved on host | None |

New switches to Previous after the successful host save. MacForm stores the raw
serialized scan and metadata under Application Support, scoped by device serial.
Previous reloads that raw blob, checks the serial, and reinterprets it with the
official library. Built-In reads `NNO_FILE_REF_CAL_DATA` and
`NNO_FILE_REF_CAL_MATRIX` with the same multi-chunk file transfer loop used for
ordinary scans. The factory cache is scoped to the connected serial and cleared
on disconnect. No reference calibration write command is used in this workflow.

For each sample, `dlpspec_scan_interpret` returns black-level-corrected sample
intensity. `dlpspec_scan_interpReference` interprets the reference blob and maps
it to the sample scan configuration. It compares the configs, scales for PGA,
and, when needed and valid, interpolates wavelength and applies the width
dependent matrix correction. An incompatible config returns an error; the host
must not silently divide unaligned arrays.

Windows `SPEC_GetReflectance` then computes interpreted sample intensity divided
by interpreted reference intensity. `SPEC_GetAbsorbance` computes
`-log10(reflectance)`. MacForm marks nonpositive inputs invalid in the data model
and omits those chart points and CSV cells. The Windows `SPEC_SetData` routine
substitutes `1` for an individual zero interpreted reference point; this is
distinct from a missing or invalid factory reference blob, which is an error.

The checked-in synthetic matrix fixture and recorded complete scan cover the
offline DLP calculation path. They do not substitute for a same-device Windows
GUI comparison or a physical white-target scan.

---

## Verified decode (DLP Spectrum Library 2.0.3)

API:

```c
DLPSPEC_ERR_CODE dlpspec_scan_interpret(const void *pBuf,
                                        const size_t bufSize,
                                        scanResults *pResults);
```

Return `DLPSPEC_PASS` (0) on success.

### Tested device snapshot (do not hardcode)

| Field | Value |
|-------|-------|
| Model | NIR-M-R2 |
| Serial | `C36R011` |
| Firmware (Tiva SW) | 2.6.3 |
| Scan config name | `Hadamard 1` |
| Scan type | Hadamard (`SCAN_TYPES = 1`) |
| Raw size | **3822 B** (TPL-serialized, magic `tpl\0`) |
| Points | **228** |
| Wavelength range | **901.816 – 1701.175 nm** |
| PGA | 64 |

Same config, 5 consecutive scans:

```text
wavelength axis |Δwl| = 0.000000 nm
```

Golden fixture in this repo:

```text
Tests/NIRMacTests/Fixtures/scan_hadamard1_C36R011.bin
```

Expected decode (tolerance 1e-3 nm on wavelength):

```text
return = DLPSPEC_PASS
points = 228
first  : 901.816 nm
last   : 1701.175 nm
```

Intensities are **per-capture** (fixture first/last: 1522 / 615).
Wavelength axis is the stable golden invariant.

> These values describe the tested configuration only.
> Do not hardcode them for other configurations / devices.

### Scan config fields from `scanResults.cfg`

After interpret, `scanResults.cfg` is a `slewScanConfig`:

- `head.scan_type` is a **wrapper** (`SLEW_TYPE` on this lib fill path).
- Real type: `dlpspec_scan_slew_get_cfg_type()` / section type when `num_sections == 1`.
- `section[i].wavelength_start_nm` / `wavelength_end_nm` / `width_px` / `num_patterns`
- `head.num_repeats` — device-side hardware repeats (not host repeat count)
- `head.config_name` — e.g. `Hadamard 1`

Protocol side (independent of decode):

- `SCAN_CFG_NUM` (0x22) → config count
- `SCAN_GET_ACT_CFG` (0x23) → active config index

Do not invent missing fields. Show `—` when absent.

---

## Error taxonomy (host should distinguish)

| Condition | Detect | Recovery |
|-----------|--------|----------|
| Device not found | enumerate empty | UI: No spectrometer connected |
| Device disconnected | enumerate empty after connect / IO error | Tear down, wait for replug |
| USB write failed | write < 0 | Mark disconnected or retry |
| USB read timeout | no response in budget | Fail command; resync |
| Protocol error | bad seq / bad length / unexpected cmd | Fail command |
| Scan timeout | `SCAN_GET_STATUS` never 1 | Abort scan, stay connected if still present |
| FILE_GET_DATA truncated | received < expected | Fail scan, keep partial raw |
| DLP decode failed | `dlpspec_scan_interpret != 0` | Fail scan, keep raw |
| Invalid spectrum | 0 points / non-finite / out of NIR range | Reject |
| Save failed | filesystem error | Report; **do not** change connection state |

---

## Debug log tags

Enable on the host when diagnosing:

```text
[USB]    TX/RX reports, open/close
[PROTO]  command / group / sequence
[SCAN]   scan phases and timings
[FILE]   expected / received byte counts
[DLP]    decode PASS/FAIL and point counts
[APP]    GUI lifecycle
```

Example:

```text
[SCAN] starting complete scan
[SCAN] expected time 1240 ms
[FILE] expected 3822 bytes
[FILE] received 3822 bytes
[DLP] decode PASS, 228 points
```

---

## Hot-plug (Phase 1 polling)

Host polls VID/PID presence about every 1 s (not IOHIDManager callbacks yet).

Required behavior:

1. App start, no device → `No spectrometer connected`
2. Insert → auto discover → auto connect → refresh Device Info
3. Device already present at start → auto connect
4. Unplug while connected → `Connected` → `Disconnected` (no crash, no stale Connected)
5. Replug → `Disconnected` → `Connecting`/`Reconnecting` → `Connected` without app restart

During an active scan, presence loss must cancel the scan and recover to Idle.

---

## Minimal ESP32-S3 port checklist

1. USB Host HID, 64-byte no Report ID
2. Implement the 7-byte header + sequence
3. Serialize all commands
4. Complete scan flow above
5. **Loop `FILE_GET_DATA` until size matches**
6. Call `dlpspec_scan_interpret` (port DLP Spectrum Library 2.0.3)
7. Validate spectrum (count, finite, NIR range, monotonic wavelengths)
8. Handle hot-plug and timeouts as in the error table

This document is the contract for that port. When live behavior changes, update this file in the same commit as the MacForm code.
