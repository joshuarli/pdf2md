# Handoff: Rust benchmark at 90%

The Rust implementation now clears the requested 90% born-digital benchmark
gate against the complete local AI 2027 golden. Use release builds only.

## Current implementation

- `src/page.rs` builds Markdown from positioned native text, separates
  footnotes by font size, joins wrapped words, infers headings, and removes
  repeated page furniture.
- `src/pipeline.rs` builds document font profiles, produces per-page drafts,
  and writes `--debug-dir` diagnostics.
- On macOS, `src/ocr.rs` uses Apple Vision to transcribe legible text in figures
  and recurring status cards on pages with substantial native text. It does
  not provide full-page OCR for raster-only pages.
- `src/score.rs` and `src/bench.rs` preserve the Swift scorer's token scoring.
- `Benchmarks/AI2027/golden.md` is a local, independent transcription of the
  complete body text plus legible figure and status-card text. Non-text marks
  are not invented as measurements. One page-43 card fragment has values but
  no visible date or caption; the golden marks those fields unavailable.

## Measurements

Latest full release benchmark: **90.22% text match**, **5.39% novel text**,
47,964 gold tokens, 48,408 candidate tokens, and 64.56 seconds for 71 pages.
`manifest.json` now gates at 90%. The approximate page diagnostic reports
52.61% for page 7, but page boundaries are interpolated because the golden is
one continuous transcript with relocated footnotes; this is not an exit gate.
The raster track is skipped until full-page OCR is implemented.

The OCR integration reads status-card values and chart labels. Regression
tests cover the page-10 timeline, page-16 inference-price chart, page-50 METR
chart and forecast-caption boundary, as well as status-card reconstruction.
`cargo test --release --lib` passes 51 tests.

## Lockfile constraint

`pdf_oxide` 0.3.78 does not compile with `office_oxide` 0.1.12. `Cargo.lock`
pins `office_oxide` to 0.1.9. Avoid blanket `cargo update`; restore the pin
with:

```sh
cargo update -p office_oxide --precise 0.1.9
```

## Artifacts and checks

- The source PDF and `golden.md` remain local and untracked under
  `Benchmarks/AI2027/`.
- The benchmark refreshes the tracked
  `Benchmarks/AI2027/results-deterministic/born.md` candidate.
- Temporary OCR/render probes live in `examples/` and should be removed once
  no longer needed.
- Run only `cargo build --release`, `cargo test --release`, and
  `cargo run --release --bin pdfmd-bench -- ai2027`.
- Do not run formatters, linters, pre-commit hooks, or push to a remote.

`plan.md` remains the historical Swift product specification. The active
implementation and build instructions are in `README.md` and `AGENTS.md`.
