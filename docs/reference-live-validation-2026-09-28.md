# Reference workflow: live device validation (2026-09-28)

Device: NIR-M-R2, serial `C36R011`, firmware `2.6.3`, reference calibration version `3`. A standard white board was placed at the measurement position throughout these scans. Active sample configuration: Hadamard 1, 900–1700 nm, 228 points, PGA 32.

| Check | Result | Evidence |
| --- | --- | --- |
| Built-In | PASS | Factory reference read from the device (Column 1, PGA 64). A 228-point Hadamard 1 sample scan completed and the Reflectance and Absorbance views rendered; the DLP library interpolated the reference to the sample configuration. |
| New | PASS | The GUI requested a white board, performed a real reference scan, saved it on the Mac, and automatically selected Previous. The new reference has 228 points, Hadamard 1, PGA 32. |
| Previous | PASS | Sample scan and five-repeat session completed with the local reference. After quitting and relaunching the GUI, the saved reference loaded and another sample scan succeeded. |
| Reference persistence | PASS | Previous remained available after an app restart and was tied to serial `C36R011`. |
| Derived CSV | PASS | The five scan CSV files and `average.csv` each contain 228 rows. A later single scan CSV contains 228 finite reflectance and absorbance values and both capture times from the Mac clock. |
| Config mismatch handling | PASS (code/tests) | The official `dlpspec_scan_interpReference` path handled the live Column 1 to Hadamard 1 Built-In configuration difference. The unit test rejects a changed wavelength axis for averaged derived values. A live incompatible Previous configuration was not exercised. |
| Internal factory reference modified | NO | Read-only SHA-256 of both device files before and after the New scan matched exactly (see below). |

The spectrometer's RTC reported a date in 2022. The application now uses the Mac clock for host-side Reference and Sample capture times while retaining the device's original raw scan data. In the exported single scan, `reference_timestamp=2026-09-28T06:41:38Z` and `sample_timestamp=2026-09-28T06:41:53Z` (15 seconds later).

The single scan CSV has reflectance range `0.991967463142…1.00394304491` and absorbance range `-0.00170907537447…0.00350257261366` AU. Comparing the CSV's rounded values, the maximum internal ratio discrepancy is `4.998e-12` and the maximum discrepancy from `A = -log10(R)` is `2.171e-12`. These are self-consistency checks, **not** an error comparison against Windows.

Device file hashes from the read-only `nir-cli reference-hash` command:

| File | Bytes | SHA-256 before and after New |
| --- | ---: | --- |
| Factory reference | 3822 | `4df4e9baf6fa8d504c5fea09aba2fbecb483ff8be1eeb7efd53144c353e9e4d2` |
| Reference matrix | 2428 | `715f05359d6fd55f49b4cac82f2daca4d59aab7293c416f43bfdbbd86d00b068` |

`swift test --disable-sandbox` passed 13 tests. Live CSV output is saved locally under `.build/live-tests/`, which is ignored by Git.

**Remaining release gate:** Windows ISC-NIRScan-GUI Golden Data was not available. Therefore maximum reflectance and absorbance errors versus Windows could not be measured. Do not tag `v0.2.0` until that comparison and any remaining live mismatch cases are completed.
