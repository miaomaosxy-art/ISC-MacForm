# dlpspec DWARF layout (vendor EasyNIR `dlpspec*.o`)

Extracted from `二次开发资料SDK/SDK for Linux/X64/libeasynirlib.a.1.1.2`
objects `dlpspec_scan.o`, `dlpspec_helper.o`, `dlpspec_types.h` decl lines.

Source paths recorded in DWARF:

- `/home/wangdh/Workspace/easy_nir/library/ubuntu-64bits/src/dlpspec_scan.c`
- `.../src/dlpspec_scan.h`
- `.../src/dlpspec_types.h`
- `.../src/dlpspec_helper.c`
- `.../src/tpl.c` (`$Id: tpl.c 192 2009-04-24 10:35:30Z thanson $`)

## Official API (DWARF)

```c
DLPSPEC_ERR_CODE dlpspec_scan_interpret(const void *pBuf,
                                        const size_t bufSize,
                                        scanResults *pResults);
```

Related: `dlpspec_scan_read_data`, `dlpspec_deserialize`, `dlpspec_serialize`,
`dlpspec_get_serialize_dump_size`, `dlpspec_scan_had_interpret`,
`dlpspec_scan_col_interpret`.

## calibCoeffs (dlpspec_types.h:58-62) sizeof=0x30

| Offset | Field | Type |
|--------|-------|------|
| 0x00 | ShiftVectorCoeffs | double[3] |
| 0x18 | PixelToWavelengthCoeffs | double[3] |

## scanResults (dlpspec_scan.h:241-251) sizeof=0x2960

| Offset | Field | Type |
|--------|-------|------|
| 0x00 | header_version | uint32_t |
| 0x04 | scan_name | char[20] |
| 0x18 | year, month, day, day_of_week, hour, minute, second | uint8_t ×7 |
| 0x20 | system_temp_hundredths | int16_t |
| 0x22 | detector_temp_hundredths | int16_t |
| 0x24 | humidity_hundredths | uint16_t |
| 0x26 | lamp_pd | uint16_t |
| 0x28 | scanDataIndex | uint32_t |
| 0x30 | calibration_coeffs | calibCoeffs |
| 0x60 | serial_number | char[8] |
| 0x68 | adc_data_length | uint16_t |
| 0x6a | black_pattern_first | uint8_t |
| 0x6b | black_pattern_period | uint8_t |
| 0x6c | pga | uint8_t |
| 0x6e | cfg | slewScanConfig |
| 0xd8 | wavelength | double[864] |
| 0x1bd8 | intensity | int[864] |
| 0x2958 | length | int |

## SCAN_TYPES

| Name | Value |
|------|-------|
| COLUMN_TYPE | 0 |
| HADAMARD_TYPE | 1 |
| SLEW_TYPE | 2 |

## DLPSPEC_ERR_CODE

| Name | Value |
|------|-------|
| DLPSPEC_PASS | 0 |
| ERR_DLPSPEC_FAIL | -1 |
| ERR_DLPSPEC_NULL_POINTER | -2 |
| ERR_DLPSPEC_INSUFFICIENT_MEM | -3 |
| ERR_DLPSPEC_INVALID_INPUT | -4 |
| ERR_DLPSPEC_TPL | -5 |
| ERR_DLPSPEC_ILLEGAL_SCAN_TYPE | -6 |

## scan_complete.bin (live NIR-M-R2)

- Size 3822 B, TPL-serialized (`tpl\0` magic, signature `S(uc#cccccccjjvvu$(f#f#)c#vccc)`)
- Embedded name `Hadamard 1`, serial `C36R011`
- Must be fed to `dlpspec_scan_interpret` — not cast to `scanResults` directly
