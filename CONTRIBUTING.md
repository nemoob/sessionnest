# Contributing

Branch from the current mainline and keep each change surgical. Add focused tests for new behavior
and regression tests for fixes when practical. Prefer the Swift standard library and native Apple
frameworks over additional packages.

Before opening a pull request, run:

```bash
Scripts/check.sh
```

The full check includes a deterministic synthetic benchmark for 20,000 Token checkpoints. It uses
temporary generated JSONL only and fails when scanning exceeds the documented five-second
regression budget. Run it independently with:

```bash
xcrun swift test --filter SessionPerformanceBenchmarkTests
```

New dependencies require maintainer agreement before implementation.
