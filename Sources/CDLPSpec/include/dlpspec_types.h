/*
 * dlpspec_types.h — type layouts recovered from vendor lib DWARF
 * (libeasynirlib.a / dlpspec_*.o, source paths:
 *   .../src/dlpspec_types.h, .../src/dlpspec_scan.h)
 *
 * These are the official TI DLP Spectrum Library structure layouts as compiled
 * into the vendor EasyNIR static library. Field names, sizes, and offsets match
 * DWARF exactly (see docs/dlpspec-dwarf-layout.md).
 *
 * NOT a reimplementation of dlpspec algorithms. For algorithm code, use official
 * TIDCC49 / TIDCC50 DLP Spectrum Library source and place it under
 * third_party/DLPSpectrumLibrary/.
 */
#ifndef DLPSPEC_TYPES_H
#define DLPSPEC_TYPES_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    DLPSPEC_PASS = 0,
    ERR_DLPSPEC_FAIL = -1,
    ERR_DLPSPEC_NULL_POINTER = -2,
    ERR_DLPSPEC_INSUFFICIENT_MEM = -3,
    ERR_DLPSPEC_INVALID_INPUT = -4,
    ERR_DLPSPEC_TPL = -5,
    ERR_DLPSPEC_ILLEGAL_SCAN_TYPE = -6
} DLPSPEC_ERR_CODE;

typedef enum {
    COLUMN_TYPE = 0,
    HADAMARD_TYPE = 1,
    SLEW_TYPE = 2
} SCAN_TYPES;

/* dlpspec_types.h:58-62 */
typedef struct {
    double ShiftVectorCoeffs[3];        /* offset 0x00 */
    double PixelToWavelengthCoeffs[3];  /* offset 0x18 */
} calibCoeffs; /* sizeof = 0x30 */

#ifdef __cplusplus
}
#endif

#endif /* DLPSPEC_TYPES_H */
