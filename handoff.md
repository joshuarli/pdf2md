# Handoff: Rust port complete

The Swift-to-Rust replacement reached the parity bar and the Swift source tree
has been removed. The current implementation is the root Cargo package, pinned
to Rust `nightly-2026-09-15` and `pdf_oxide` 0.3.78.

## Current implementation

- `src/page.rs` builds lines and paragraphs from positioned spans, separates
  footnotes by document font sizes, rewrites matching raised markers, joins
  lowercase line-break hyphens, infers display headings, strips tagged and
  repeated margin furniture, and repairs tracked single-letter text.
- `src/pipeline.rs` creates document-wide font profiles and per-page drafts;
  markerless footnote continuations join the previous definition.
- `--debug-dir` writes `page-NNNN.json` files and a `document.json` manifest
  with block kinds, normalized regions, native character counts, and drafts.
- `src/score.rs` and `src/bench.rs` preserve the Swift scorer's token score.
- `src/bin/pdfmd-bench.rs` runs the born-digital benchmark. The raster track
  is explicitly skipped because OCR was declined.

## Measurements

Against the earlier prose-only golden, the AI 2027 result was 89.77% text
match / 5.65% novel text in 0.16 seconds for 71 pages; the former Swift result
was 89.57% on that same reference. The local golden now includes a page-keyed
transcript of legible text in figures and recurring status cards. Against
that expanded reference, the current Rust candidate scores 84.63% match /
5.69% novel text. The earlier parity comparison does not establish parity on
the expanded reference. The benchmark still exits nonzero because
`manifest.json` retains the original 99% project target. The reported worst
interpolated page is 47.93%; page scoring is approximate because the golden
transcription has no page separators and relocates footnotes.

On `gelato.pdf`, repeated Italian and English rights notices are removed,
`angelo corvitto` is no longer letter-spaced, and centered credit lines remain
paragraphs. OCR remains out of scope.

## Lockfile constraint

pdf_oxide 0.3.78 does not compile with `office_oxide` 0.1.12 because of an
upstream struct change. `Cargo.lock` pins `office_oxide` to 0.1.9. Do not run a
blanket `cargo update`; restore the pin with:

```sh
cargo update -p office_oxide --precise 0.1.9
```

## Checks

- `cargo test --release` — 13 tests pass.
- `cargo build --release` — passes.
- `target/release/pdfmd-bench ai2027` — 89.77% against the earlier
  prose-only golden; exits 1 at the retained 99% manifest target. The current
  expanded-golden score is 84.63% via the read-only `score` command.
- The local raster benchmark was not run because the CLI has no OCR.

`plan.md` remains the original Swift product specification and historical
design record. The active build, usage, and dependency instructions are in
`README.md` and `AGENTS.md`.
