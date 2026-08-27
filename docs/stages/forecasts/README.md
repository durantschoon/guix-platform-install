# Branch Forecasts

Each implementation stage may have a sealed forecast committed before its
executor launches:

- `stage-NN-FORECAST.sealed` is the gzip-plus-base64 sealed forecast.
- `stage-NN-FORECAST.sealed.sha256` commits to the plaintext forecast.
- Neither file may be unsealed until the stage is merged or abandoned.
- Resolution creates `stage-NN-FORECAST-RESOLVED.md`, annotated with outcomes
  and evidence, beside the stage REPORT.

Sealing prevents the executor from turning a prediction into a
self-fulfilling result and prevents the coordinator from anchoring review on
its own forecast. Resolution includes an unmodeled-pivot sweep so calibration
measures both probability accuracy and branch coverage.
