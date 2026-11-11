# lumasight Diagnostic Tools

Standalone developer utilities in `tools/` compile directly against the pure Swift logic in `lumasight/` without requiring an app bundle or persistent models.

## Included Scripts

- `liveness_selftest.swift` — Camera-free unit test for geometric planar-vs-3D separation and the experimental 2D liveness cue state machine:
  ```bash
  swiftc -O -o /tmp/liveness_selftest \
    lumasight/Liveness/LandmarkGeometry.swift \
    lumasight/Liveness/GeometryLiveness.swift \
    lumasight/Liveness/GlareCue.swift \
    lumasight/Liveness/LivenessCues.swift \
    lumasight/Liveness/LivenessScoring.swift \
    lumasight/Liveness/LivenessAnalyzer.swift \
    tools/liveness_selftest.swift && /tmp/liveness_selftest
  ```
- `glare_cue_probe.swift` — Offline specular glare probe against image files you pass on the command line:
  ```bash
  swiftc -O -o /tmp/glare_cue_probe \
    lumasight/Liveness/GlareCue.swift \
    lumasight/Liveness/GlareCueExtractor.swift \
    lumasight/Liveness/LivenessCues.swift \
    lumasight/Liveness/LivenessScoring.swift \
    lumasight/Liveness/LandmarkGeometry.swift \
    lumasight/Liveness/GeometryLiveness.swift \
    tools/glare_cue_probe.swift && /tmp/glare_cue_probe path/to/live.jpg path/to/screen.jpg
  ```
