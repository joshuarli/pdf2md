# pdfmd

Native Rust CLI: PDF → faithful Markdown. `pdf_oxide` extracts positioned
native text; the pipeline assembles it into per-page Markdown. OCR is not part
of this build. The original product specification is in `plan.md`.

## Layout

```text
src/             — all conversion and benchmark logic
src/bin/         — separate benchmark runner, kept out of `pdfmd --help`
Benchmarks/AI2027 — manifest and notes; PDF and golden.md stay local/untracked
```

## Rules

- Use `pdf_oxide` and the crates already listed in `Cargo.toml`. Apple Vision
  bindings are approved for selective figure and status-card transcription;
  ask before adding other dependencies.
- Make small reversible changes; tie deterministic heuristics to a failing
  fixture or benchmark page.
- Fix native-text extraction and layout bugs deterministically. Apple Vision
  is for text drawn inside figures and status cards, not a fallback for missing
  native body text.
- `cargo test --release` must never need network access, Vision recognition,
  model files, or Homebrew.
- stdout is clean Markdown only. Normal errors are one line on stderr.
- Comments explain why, especially for coordinate transforms, span grouping,
  footnote placement, and benchmark-driven thresholds.
- Do not run formatters, linters, or pre-commit hooks; the user runs those.
- Never push to a remote unless explicitly told.

## Build

- `cargo build --release` / `cargo test --release`
- `make install` installs both binaries to `~/usr/bin` by default
- `cargo run --release --bin pdfmd-bench -- ai2027` runs the benchmark
