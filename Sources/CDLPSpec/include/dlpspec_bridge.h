#ifndef DLPSPEC_BRIDGE_H
#define DLPSPEC_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int     count;
    double *wavelength;   /* malloc'd, free with nir_free_decoded_scan */
    int    *intensity;    /* malloc'd */
    double  temperature;      /* system_temp_hundredths / 100.0 */
    double  detector_temperature;
    double  humidity;         /* humidity_hundredths / 100.0 */
    int16_t system_temp_hundredths;
    int16_t detector_temp_hundredths;
    uint16_t humidity_hundredths;
    uint8_t  pga;
    char     scan_name[20];
    char     serial_number[8];
    uint8_t  year, month, day, hour, minute, second;
    int32_t  return_code;     /* DLPSPEC_ERR_CODE */
    char     message[256];

    /* Serialized scan config fields from scanResults.cfg (slewScanConfig).
       Only values present in the official structure; -1 / 0xFF when unknown. */
    int16_t  cfg_scan_type;          /* SCAN_TYPES: 0 Col, 1 Had, 2 Slew */
    uint16_t cfg_scan_config_index;
    char     cfg_config_name[40];
    uint16_t cfg_wavelength_start_nm;
    uint16_t cfg_wavelength_end_nm;
    uint8_t  cfg_width_px;
    uint16_t cfg_num_patterns;
    uint16_t cfg_num_repeats;
    uint8_t  cfg_num_sections;
} NIRDecodedSpectrum;

/* Returns 0 on success (DLPSPEC_PASS). */
int nir_decode_scan(const uint8_t *data, size_t size, NIRDecodedSpectrum *result);

void nir_free_decoded_scan(NIRDecodedSpectrum *result);

/* 1 if linked against official dlpspec_scan_interpret. */
int nir_dlpspec_available(void);

const char *nir_dlpspec_version_string(void);

#ifdef __cplusplus
}
#endif

#endif
