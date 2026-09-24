# pdfmd

`pdfmd` converts PDF native text into clean Markdown using Rust and
[`pdf_oxide`](https://crates.io/crates/pdf_oxide). It groups positioned text
spans into paragraphs, recognizes display headings, moves footnotes to page
end, and removes repeated page furniture. The CLI does not run OCR and makes
no network requests.

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
- `pdf_oxide` plus the directly listed serialization, hashing, regex, and
  Unicode crates in `Cargo.toml`
- No OCR engine, model download, or runtime network access

## Build and check

```bash
cargo build
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

The current deterministic Rust result is 89.77% text match and 5.65% novel
text, measured in 0.16 seconds for 71 pages. This is above the prior Swift
result of 89.57%. The benchmark manifest retains the broader 99% target, so
the runner still reports that gate as failed. The raster track is reported as
skipped because this build has no OCR. Details and historical measurements are
in `Benchmarks/AI2027/README.md`.

## Privacy and limitations

PDF content stays on the device. Conversion uses the text layer present in the
PDF; scanned or image-only pages need OCR and are not recognized by this
build. The benchmark PDF, raster twin, and golden transcription remain local
and untracked.
