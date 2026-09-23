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
    return "DLP Spectrum Library (vendor objects / TIDCC49-compatible API)";
}

int nir_decode_scan(const uint8_t *data, size_t size, NIRDecodedSpectrum *result)
{
    if (!data || !result || size == 0) {
        return -1;
    }
    memset(result, 0, sizeof(*result));

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
