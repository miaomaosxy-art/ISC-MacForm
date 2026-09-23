/*
 * Offline NIR-M-R2 complete-scan interpreter.
 * Calls official dlpspec_scan_interpret() — no reimplementation.
 *
 * Build (once TI DLP Spectrum Library source is in third_party/DLPSpectrumLibrary):
 *   ./scripts/build-dlpspec.sh
 *   ./scripts/build-interpret-tool.sh
 *   ./build/interpret_scan scan_complete.bin [scan.csv]
 */
#include "dlpspec_bridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void print_pairs(const NIRDecodedSpectrum *s, int from, int to)
{
    if (s->count <= 0) {
        return;
    }
    if (from < 0) {
        from = 0;
    }
    if (to > s->count) {
        to = s->count;
    }
    for (int i = from; i < to; i++) {
        printf("  [%4d]  %10.3f nm  %d\n", i, s->wavelength[i], s->intensity[i]);
    }
}

static int write_csv(const NIRDecodedSpectrum *s, const char *path)
{
    FILE *f = fopen(path, "w");
    if (!f) {
        perror(path);
        return -1;
    }
    fprintf(f, "wavelength_nm,intensity\n");
    for (int i = 0; i < s->count; i++) {
        fprintf(f, "%.3f,%d\n", s->wavelength[i], s->intensity[i]);
    }
    fclose(f);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s scan_complete.bin [scan.csv]\n", argv[0]);
        return 2;
    }

    FILE *f = fopen(argv[1], "rb");
    if (!f) {
        perror(argv[1]);
        return 1;
    }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz <= 0 || sz > 8 * 1024 * 1024) {
        fprintf(stderr, "bad file size %ld\n", sz);
        fclose(f);
        return 1;
    }
    uint8_t *buf = (uint8_t *)malloc((size_t)sz);
    if (!buf || fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
        fprintf(stderr, "read failed\n");
        fclose(f);
        free(buf);
        return 1;
    }
    fclose(f);

    printf("Input file         : %s (%ld bytes)\n", argv[1], sz);
    printf("DLP Spectrum decode: ");
    fflush(stdout);

    NIRDecodedSpectrum s;
    memset(&s, 0, sizeof(s));
    int rc = nir_decode_scan(buf, (size_t)sz, &s);
    free(buf);

    if (rc != 0) {
        printf("FAIL\n");
        printf("dlpspec version    : %s\n", nir_dlpspec_version_string());
        printf("return code        : %d\n", s.return_code);
        printf("message            : %s\n", s.message);
        printf("scan size          : %ld\n", sz);
        nir_free_decoded_scan(&s);
        return 1;
    }

    printf("PASS\n");
    printf("Scan name          : %.19s\n", s.scan_name);
    printf("Serial             : %.8s\n", s.serial_number);
    printf("Scan type/config   : %s\n", s.scan_name);
    printf("Points             : %d\n", s.count);
    if (s.count > 0) {
        double lo = s.wavelength[0], hi = s.wavelength[0];
        for (int i = 1; i < s.count; i++) {
            if (s.wavelength[i] < lo) lo = s.wavelength[i];
            if (s.wavelength[i] > hi) hi = s.wavelength[i];
        }
        printf("Wavelength range   : %.3f - %.3f nm\n", lo, hi);
    }
    printf("Temperature        : %.2f C (detector %.2f C)\n", s.temperature, s.detector_temperature);
    printf("Humidity           : %.2f %%\n", s.humidity);
    printf("PGA                : %u\n", (unsigned)s.pga);
    printf("Timestamp          : %04u-%02u-%02u %02u:%02u:%02u\n",
           2000u + s.year, s.month, s.day, s.hour, s.minute, s.second);

    printf("First points:\n");
    print_pairs(&s, 0, s.count < 10 ? s.count : 10);
    printf("Last points:\n");
    print_pairs(&s, s.count > 10 ? s.count - 10 : 0, s.count);

    if (argc >= 3) {
        if (write_csv(&s, argv[3 - 1]) == 0) {
            printf("Saved CSV          : %s\n", argv[2]);
        }
    }

    nir_free_decoded_scan(&s);
    return 0;
}
