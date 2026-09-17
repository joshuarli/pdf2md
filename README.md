# pdfmd

`pdfmd` extracts a PDF into clean, faithful Markdown using only macOS system
frameworks: PDFKit (native text + rasterization), Vision
`RecognizeDocumentsRequest` (structure + OCR), and Apple Foundation Models
(selective visual repair). See `plan.md` for the full specification.

## Layout

```
Sources/PdfmdCore    — pipeline: CLI parsing, PDF access, geometry, Page IR,
                       Vision extraction, dedup, reading order, reconciliation,
                       rendering, repair, scoring (testable logic)
Sources/pdfmd        — thin CLI entry point (stdout/stderr discipline, exit codes)
Sources/pdfmd-bench  — benchmark runner (kept out of `pdfmd --help`)
Tests/PdfmdCoreTests — unit tests (Swift Testing, no network, no model)
Benchmarks/AI2027    — manifest + methodology notes (PDF and gold stay local)
```

`pdfmd` and `pdfmd-bench` are thin; the pipeline lives in `PdfmdCore` so it
is testable. No config, no daemon, no networking, no third-party dependencies.

## Requirements

- macOS 26+. The deterministic pipeline and text-only model repair run
  everywhere; the page image reaches Foundation Models only on macOS 27+
  (plan.md section 2.1).
- Swift 6.3, Swift 6 language mode, `NonisolatedNonsendingByDefault`, strict
  memory safety. Zero package dependencies.

## Build

- `swift build` — debug build
- `swift build -c release` — optimized build
- `swift test` — unit tests (deterministic only; never touches the model)
- `make install` — release build, install `pdfmd` + `pdfmd-bench` to `~/usr/bin`
- `swift run pdfmd-bench ai2027` — AI 2027 benchmark (needs local PDF + gold)

## Usage

```bash
pdfmd INPUT.pdf
pdfmd INPUT.pdf -o OUTPUT.md
pdfmd INPUT.pdf --pages 1,3-7,12
pdfmd INPUT.pdf --debug-dir DIR
pdfmd --help
pdfmd --version
```

Defaults: whole document, Markdown to stdout (`-o` omitted), diagnostics and
progress to stderr only, 1-based page numbers. No AI/model/OCR-engine flags:
Foundation Models are an internal repair detail, used selectively, and normal
conversion never requires Apple Intelligence.

## Privacy

PDF content never leaves the Mac. No network requests, no cloud OCR, no remote
models. The benchmark PDF and golden Markdown stay local/untracked (see
`Benchmarks/AI2027/README.md`).

## Architecture

```
PDFKit native text + geometry ─┐
                               ├─► canonical Page IR ─► deterministic Markdown ─┐
Vision RecognizeDocumentsRequest ┘        (dedup, reading order)                │
                        ambiguous/complex pages only                            │
                          Foundation Models + page image ─► fidelity guard ──────┘
```

Every page renders useful Markdown without the model. Complex pages get one
bounded repair attempt; failed validation falls back to the deterministic
draft. Large documents stream serially with bounded memory (page bitmaps are
released promptly; only lightweight Page IR is retained).

## Benchmark methodology

`Benchmarks/AI2027/` pins the source PDF by SHA-256 and scores normalized,
order-sensitive token fidelity (`1 - edit_cost / gold_tokens`) plus a
separately reported novel-text rate. Born-digital target: >=99% match.
Raster-only twin target: >=95% match with <1% novel text. Details and
licensing cautions live in `Benchmarks/AI2027/README.md`.

## Known limitations

- Multimodal Foundation Models image repair is availability-gated: the model
  receives the page image only on macOS 27+ (`if #available`). On macOS 26
  the repair stage runs text-only from structured Page IR plus the
  deterministic draft, and the pipeline measures that result first.
- Native/Vision spatial reconciliation is policy-level; geometric word-level
  alignment lands with Phase 2 benchmark evidence.
- The installed Xcode 26.6 SDK has no macOS 27 image-attachment API, so the
  27-only call sites remain the documented insertion point in
  `FoundationRepairer` until an Xcode 27 toolchain is available.
