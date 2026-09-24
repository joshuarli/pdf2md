# pdfmd

`pdfmd` converts PDF native text into clean Markdown using Rust and
[`pdf_oxide`](https://crates.io/crates/pdf_oxide). It groups positioned text
spans into paragraphs, recognizes display headings, moves footnotes to page
end, and removes repeated page furniture. On macOS, Apple Vision adds legible
text from figures and recurring status cards to a visual appendix. The CLI
makes no network requests.

## Layout

```text
src/             — conversion, CLI, output, scoring, and benchmark logic
src/bin/         — separate pdfmd-bench executable
Benchmarks/AI2027 — benchmark manifest and notes; PDF and golden stay local
```

`plan.md` is the original product specification and records the earlier Swift
design. The active implementation is the Rust crate at the repository root.

## Requirements

- Rust `nightly-2026-09-15` (pinned in `rust-toolchain.toml`)
- `pdf_oxide`, the directly listed parsing crates, and macOS Apple Vision
  bindings in `Cargo.toml`
- No model download or runtime network access

## Build and check

```bash
cargo build --release
cargo test --release
make install
```

`make install` installs `pdfmd` and `pdfmd-bench` to `~/usr/bin` by default.
Set `PREFIX` to choose another install prefix.

## Usage

```bash
pdfmd INPUT.pdf
pdfmd INPUT.pdf -o OUTPUT.md
pdfmd INPUT.pdf --pages 1,3-7,12
pdfmd INPUT.pdf --debug-dir DIR
pdfmd --help
pdfmd --version
```

Defaults: convert the whole document and write Markdown to stdout. Diagnostics
go to stderr. Page numbers are 1-based. `--debug-dir` writes one JSON record per
selected page, including block kinds, normalized regions, and the final draft.

## Benchmark

Run the born-digital AI 2027 benchmark with:

```bash
cargo run --release --bin pdfmd-bench -- ai2027
```

The current result is 90.22% text match and 5.39% novel text across 71 pages;
the manifest gate is 90%. Conversion took 64.56 seconds on the measured
machine, including selective Vision recognition for figure and card text.
Raster-only pages still need full-page OCR, so that track is reported as
skipped. Details and historical measurements are in
`Benchmarks/AI2027/README.md`.

## Privacy and limitations

PDF content stays on the device. Native text is used for page content, with
Apple Vision used for selected visual labels. Scanned and image-only pages are
not yet transcribed. The benchmark PDF, raster twin, and golden transcription
remain local and untracked.
