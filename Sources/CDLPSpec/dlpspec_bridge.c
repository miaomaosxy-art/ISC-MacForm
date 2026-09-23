/*
 * Stable C bridge over official dlpspec_scan_interpret().
 * Does not reimplement spectrum math — only adapts scanResults to flat arrays.
 */
#include "dlpspec_bridge.h"
#include "dlpspec_scan.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int nir_dlpspec_available(void)
{
    return 1;
}

const char *nir_dlpspec_version_string(void)
{
    return "2.0.3";
}

/* Extract slewScanConfig fields from scanResults.cfg blob at DWARF offset 0x6e.
 *
 * Layout (dlpspec_scan.h slewScanConfig / slewScanConfigHead + slewScanSection):
 *   +0   u8  scan_type
 *   +2   u16 scanConfigIndex
 *   +4   c[8] serial
 *   +12  c[40] config_name
 *   +52  u16 num_repeats
 *   +54  u8  num_sections
 *   +56  section[0]: u8 type, u8 width_px, u16 start_nm, u16 end_nm,
 *                    u16 num_patterns, u16 exposure_time   (10 bytes each)
 *
 * Official helpers dlpspec_scan_slew_get_* cover type/patterns/end_nm;
 * this keeps the bridge independent of which dlpspec_scan.h is on the include path.
 */
static void extract_scan_config(const scanResults *pResults, NIRDecodedSpectrum *result)
{
    const uint8_t *cfg = (const uint8_t *)pResults + 0x6e;

    result->cfg_scan_type = (int16_t)cfg[0];
    result->cfg_scan_config_index = (uint16_t)(cfg[2] | (cfg[3] << 8));
    memcpy(result->cfg_config_name, cfg + 12, 40);
    result->cfg_config_name[39] = '\0';
    result->cfg_num_repeats = (uint16_t)(cfg[52] | (cfg[53] << 8));
    result->cfg_num_sections = cfg[54];

    /* Section 0 holds the single-scan (Hadamard/Column) range and width.
       For multi-section Slew, take min start / max end / sum patterns. */
    if (result->cfg_num_sections == 0 || result->cfg_num_sections > 5) {
        result->cfg_wavelength_start_nm = 0;
        result->cfg_wavelength_end_nm = 0;
        result->cfg_width_px = 0;
        result->cfg_num_patterns = 0;
        return;
    }

    uint16_t min_start = 0xFFFF;
    uint16_t max_end = 0;
    uint16_t total_patterns = 0;
    uint8_t width_px = 0;
    for (int s = 0; s < result->cfg_num_sections; s++) {
        const uint8_t *sec = cfg + 56 + s * 10;
        uint8_t w = sec[1];
        uint16_t start_nm = (uint16_t)(sec[2] | (sec[3] << 8));
        uint16_t end_nm = (uint16_t)(sec[4] | (sec[5] << 8));
        uint16_t patterns = (uint16_t)(sec[6] | (sec[7] << 8));
        if (start_nm < min_start) min_start = start_nm;
        if (end_nm > max_end) max_end = end_nm;
        total_patterns = (uint16_t)(total_patterns + patterns);
        if (s == 0) width_px = w;
    }
    result->cfg_wavelength_start_nm = min_start;
    result->cfg_wavelength_end_nm = max_end;
    result->cfg_width_px = width_px;
    result->cfg_num_patterns = total_patterns;

    /* Match official dlpspec_scan_slew_get_cfg_type():
       head.scan_type is always SLEW_TYPE (wrapper). Real type is section type
       when there is exactly one section. */
    {
        const uint8_t *sec0 = cfg + 56;
        if (result->cfg_num_sections != 1) {
            result->cfg_scan_type = 2; /* SLEW_TYPE */
        } else if (sec0[0] == 0) {
            result->cfg_scan_type = 0; /* COLUMN_TYPE */
        } else {
            result->cfg_scan_type = 1; /* HADAMARD_TYPE */
        }
    }
}

int nir_decode_scan(const uint8_t *data, size_t size, NIRDecodedSpectrum *result)
{
    if (!data || !result || size == 0) {
        return -1;
    }
    memset(result, 0, sizeof(*result));
    result->cfg_scan_type = -1;
    result->cfg_width_px = 0xFF;

    /* scanResults is large (~10.5 KB); heap-allocate. */
    scanResults *pResults = (scanResults *)calloc(1, sizeof(scanResults));
    if (!pResults) {
        result->return_code = ERR_DLPSPEC_INSUFFICIENT_MEM;
        snprintf(result->message, sizeof(result->message), "calloc scanResults failed");
        return ERR_DLPSPEC_INSUFFICIENT_MEM;
    }

    DLPSPEC_ERR_CODE rc = dlpspec_scan_interpret(data, size, pResults);
    result->return_code = rc;
    if (rc != DLPSPEC_PASS) {
        snprintf(result->message, sizeof(result->message),
                 "dlpspec_scan_interpret returned %d", (int)rc);
        free(pResults);
        return (int)rc;
    }

    int n = pResults->length;
    if (n < 0 || n > 864) {
        snprintf(result->message, sizeof(result->message),
                 "invalid results length %d", n);
        free(pResults);
        return ERR_DLPSPEC_FAIL;
    }

    result->wavelength = (double *)malloc(sizeof(double) * (size_t)(n > 0 ? n : 1));
    result->intensity = (int *)malloc(sizeof(int) * (size_t)(n > 0 ? n : 1));
    if (!result->wavelength || !result->intensity) {
        nir_free_decoded_scan(result);
        free(pResults);
        result->return_code = ERR_DLPSPEC_INSUFFICIENT_MEM;
        return ERR_DLPSPEC_INSUFFICIENT_MEM;
    }

    result->count = n;
    for (int i = 0; i < n; i++) {
        result->wavelength[i] = pResults->wavelength[i];
        result->intensity[i] = pResults->intensity[i];
    }

    result->system_temp_hundredths = pResults->system_temp_hundredths;
    result->detector_temp_hundredths = pResults->detector_temp_hundredths;
    result->humidity_hundredths = pResults->humidity_hundredths;
    result->temperature = pResults->system_temp_hundredths / 100.0;
    result->detector_temperature = pResults->detector_temp_hundredths / 100.0;
    result->humidity = pResults->humidity_hundredths / 100.0;
    result->pga = pResults->pga;
    memcpy(result->scan_name, pResults->scan_name, 20);
    memcpy(result->serial_number, pResults->serial_number, 8);
    result->year = pResults->year;
    result->month = pResults->month;
    result->day = pResults->day;
    result->hour = pResults->hour;
    result->minute = pResults->minute;
    result->second = pResults->second;

    extract_scan_config(pResults, result);

    snprintf(result->message, sizeof(result->message), "OK");
    free(pResults);
    return 0;
}

void nir_free_decoded_scan(NIRDecodedSpectrum *result)
{
    if (!result) {
        return;
    }
    free(result->wavelength);
    free(result->intensity);
    result->wavelength = NULL;
    result->intensity = NULL;
    result->count = 0;
}
