/*
 * dlpspec_scan.h — structure layouts recovered from vendor lib DWARF
 * (dlpspec_scan.h line numbers match DWARF decl_line).
 *
 * Official API:
 *   DLPSPEC_ERR_CODE dlpspec_scan_interpret(const void *pBuf,
 *                                           const size_t bufSize,
 *                                           scanResults *pResults);
 *
 * Do not reimplement interpret math here. Link official dlpspec objects/source.
 */
#ifndef DLPSPEC_SCAN_H
#define DLPSPEC_SCAN_H

#include "dlpspec_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/* scanResults — DWARF sizeof 0x2960, decl_line 241-251 */
typedef struct {
    uint32_t header_version;            /* 0x00 */
    char     scan_name[20];             /* 0x04 */
    uint8_t  year;                      /* 0x18 */
    uint8_t  month;                     /* 0x19 */
    uint8_t  day;                       /* 0x1a */
    uint8_t  day_of_week;               /* 0x1b */
    uint8_t  hour;                      /* 0x1c */
    uint8_t  minute;                    /* 0x1d */
    uint8_t  second;                    /* 0x1e */
    /* pad 0x1f */
    int16_t  system_temp_hundredths;    /* 0x20 */
    int16_t  detector_temp_hundredths;  /* 0x22 */
    uint16_t humidity_hundredths;       /* 0x24 */
    uint16_t lamp_pd;                   /* 0x26 */
    uint32_t scanDataIndex;             /* 0x28 */
    /* pad 0x2c..0x2f */
    calibCoeffs calibration_coeffs;     /* 0x30, size 0x30 */
    char     serial_number[8];          /* 0x60 */
    uint16_t adc_data_length;           /* 0x68 */
    uint8_t  black_pattern_first;       /* 0x6a */
    uint8_t  black_pattern_period;      /* 0x6b */
    uint8_t  pga;                       /* 0x6c */
    /* pad 0x6d — cfg at 0x6e (slewScanConfig) */
    uint8_t  _cfg_blob[0xd8 - 0x6e];    /* slewScanConfig placeholder (full def in TI source) */
    double   wavelength[864];           /* 0xd8 */
    int      intensity[864];            /* 0x1bd8 */
    int      length;                    /* 0x2958 */
} scanResults; /* 0x2960 */

/* API used by offline interpret (official signatures from DWARF). */
DLPSPEC_ERR_CODE dlpspec_scan_interpret(const void *pBuf,
                                        const size_t bufSize,
                                        scanResults *pResults);
DLPSPEC_ERR_CODE dlpspec_scan_interpReference(const void *pRefCal,
                                              size_t calSize,
                                              const void *pMatrix,
                                              size_t matrixSize,
                                              const scanResults *pScanResults,
                                              scanResults *pRefResults);

#ifdef __cplusplus
}
#endif

#endif /* DLPSPEC_SCAN_H */
