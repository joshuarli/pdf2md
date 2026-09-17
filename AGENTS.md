# pdfmd

Native macOS CLI: PDF → faithful Markdown. Full spec is `plan.md`.

## Layout

```
Sources/PdfmdCore    — all pipeline logic (testable)
Sources/pdfmd        — thin CLI entry (stdout = Markdown only, stderr = diagnostics)
Sources/pdfmd-bench  — benchmark runner, kept out of `pdfmd --help`
Tests/PdfmdCoreTests — Swift Testing, deterministic only
Benchmarks/AI2027    — manifest + notes; PDF and golden.md stay local/untracked
```

## Rules

- Zero package dependencies. Only Apple frameworks + stdlib.
- Small reversible steps; tie heuristics to a failing fixture or benchmark page.
- Deterministic bugs get deterministic fixes — never paper over them with the model.
- `swift test` must never need network, the model, or Homebrew software.
- stdout is clean Markdown only. No stack traces on normal errors.
- Comments explain *why* (Vision quirks, coordinate transforms, containment
  rules, benchmark-driven choices), not obvious syntax.
- No formatters/linters/pre-commit hooks; the user runs those independently.

## Build

- `swift build` / `swift build -c release` / `swift test`
- `make install` → `~/usr/bin`
- `swift run pdfmd-bench ai2027` for the benchmark
