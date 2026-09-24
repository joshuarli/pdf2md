# Handoff: porting pdfmd from Swift to Rust on pdf_oxide

This is where the Swift → Rust port stands. It records the user's decisions,
what has been built and measured, and what should happen next.

## Why the port

The user was unhappy with the Swift/PDFKit/Vision pipeline. It was too slow
(about 0.8 s per page, since it ran Vision on every page), and its output for
`gelato.pdf` was poor (see the untracked `gelato.md`). They asked to port it to
[pdf_oxide](https://github.com/yfedoseev/pdf_oxide) on **Rust
`nightly-2026-09-15`**.

## Decisions the user made (treat these as fixed)

| Question | Decision |
|---|---|
| OCR for scanned or image-only pages | **None for now.** Native text only. pdf_oxide OCR (PaddleOCR via `ort`) was rejected because it downloads binaries and models. Apple Vision through objc2 remains an option for later. |
| Swift implementation | **Replace in place.** The Cargo package sits at the repo root. Delete `Package.swift`, `Sources/`, `Tests/` once the Rust version is at parity (git history keeps them). |
| Done bar | **Beat Swift on AI2027 born-digital: at least 89.57% text match.** Also add a gelato check: no repeated per-page watermark, no letter-spaced words. |
| Dependencies | `pdf_oxide` plus `sha2`, `serde`/`serde_json`, `unicode-normalization`, `regex`. All four are already in pdf_oxide's dependency tree, so they add no crates. Ask the user before adding anything else, clap included. |

## Current state (committed)

```
rust-toolchain.toml     pins nightly-2026-09-15 (installed; rustc 1.100.0-nightly 574ff7d98)
Cargo.toml / Cargo.lock package `pdfmd` (edition 2024): lib + bins `pdfmd`, `pdfmd-bench`
src/score.rs            port of DiffScore.swift + TextNormalization.swift (patience + capped Myers)
src/bench.rs            manifest (serde), SHA-256 pinning, per-page scoring (PageScore.swift port), diff hunks
src/cli.rs              hand-rolled arg parsing, same flags/messages as CLI.swift
src/output.rs           atomic write (hidden sibling temp + rename)
src/pipeline.rs         BASELINE ONLY: `doc.extract_text(page)` per page → PageDraft
src/main.rs             thin CLI; exit 0 ok / 1 conversion or IO failure / 2 usage error
src/bin/pdfmd-bench.rs  `ai2027 [--dir]`, `score`, `diff` (diff prints unmatched hunks for heuristic work)
examples/probe.rs       throwaway: dump span geometry for one page (`probe PDF PAGE`)
examples/sizes.rs       throwaway: document font-size histogram
```

- `cargo test --release`: 12 unit tests pass (scorer, CLI, per-page scoring,
  diff hunks).
- `cargo run --release --bin pdfmd-bench -- ai2027` runs the benchmark. It
  overwrote `Benchmarks/AI2027/results-deterministic/born.md` and
  `born-pages.json` with the Rust baseline output.
- **Not done yet:** `--debug-dir` is parsed but ignored. The Swift progress
  lines on stderr were intentionally dropped, since the whole conversion
  takes under a second. README.md, AGENTS.md, and the Makefile still describe
  the Swift build.

### Lockfile gotcha

pdf_oxide 0.3.78 does **not** compile against office_oxide 0.1.12 (a patch
release added the field `DocumentIR.defined_names`). `Cargo.lock` is pinned
to office_oxide **0.1.9**, the version upstream's own lockfile uses. Do not
run a blanket `cargo update`. If you do, re-run
`cargo update -p office_oxide --precise 0.1.9`.

## Measurements (AI 2027 born-digital, 45,328 gold tokens)

| Candidate | Match | Novel | Notes |
|---|---|---|---|
| Swift pipeline (current HEAD) | 89.57% | 4.87% | target to beat |
| Swift baseline A, `PDFPage.string` | 93.06% | 4.7% | raw native text already does well |
| pdf_oxide `to_markdown` | 82.37% | 9.76% | its heading and reading-order heuristics hurt |
| pdf_oxide `extract_text` (**current Rust baseline**) | **85.02%** | 8.16% | worst page 52% (p7); 0.21 s for 71 pages |
| pdf_oxide `extract_text_lines` / spans by `sequence` | about 73.6% | about 14% | raw pieces, no ordering or cleanup |

Scorer parity is verified: the Swift and Rust scorers give an identical
85.02% on the same file.

Speed: on gelato pages 1–20, Swift took 15.9 s and pdf_oxide 0.27 s. The
whole gelato book takes 1.3 s in pdf_oxide.

## Diagnosis: where the missing 15% goes

Run `pdfmd-bench diff --candidate Benchmarks/AI2027/results-deterministic/born.md --golden Benchmarks/AI2027/golden.md`
and sort hunks by size. The large hunks are not missing text. They are
**footnotes in the wrong place**, and each one costs a deletion plus an
insertion. Golden conventions (the curation rules are in
`Benchmarks/AI2027/README.md`):

- Each page renders as body paragraphs first, then that page's footnotes as
  `[^N]: text` definitions, ordered by content stream: margin numbered
  footnotes, then bottom `*`/`†`/`‡` footnotes.
- Body reference markers become `[^N]`. The scorer drops those, so an
  inline bare superscript like "DeepSeek 19 released" counts as an insertion.
- Headings are `##` (title `#`). Hyphenated line breaks are joined
  ("com-" + "puter" → "computer").
- Page numbers and running heads are dropped. Green margin pull-quotes that
  duplicate body text are excluded. A footnote that continues onto the next
  page is appended to the previous page's last definition.

### The geometry is clean (pdf_oxide `extract_spans`)

Page 3, via `cargo run --release --example probe -- ai-2027.pdf 3`. `TextSpan`
provides `text`, `bbox` (PDF coordinates, **y points up**), `font_size`,
`font_weight`, `is_italic`, `sequence` (content-stream order, which is
already correct reading order within each zone), and `artifact_type` (tagged
artifacts are candidates for watermark and running-head removal).

Font-size histogram over the whole document (chars):
`11.0` body (168k) · `9.4` footnotes (57k) · `5.6–7.7` markers · `14.0`
headings · `20`/`30`/`200` title and appendix display type · `10.0`
cover credit.

- Body column: x ≈ 42.5, width about 340. Margin footnotes: x ≈ 411, 9.4 pt.
  Bottom footnotes: x ≈ 42.5, 9.4 pt, low on the page.
- Marker in the body: a 6.6 pt span that follows body text on the same line.
  Footnote label: a 5.6 pt span that starts a 9.4 pt footnote.
- Line pitch is 14.3 pt and paragraph gaps are about 20.4 pt. Spans on one
  baseline need joining with a space only when the x-gap is more than about
  0.2 × size and the text doesn't already carry one (some spans start with
  " ").

## Planned next steps (in order; measure each with `pdfmd-bench ai2027`)

1. **Page IR from spans** (`src/page.rs` or similar). Derive the body size
   (the size with the most characters in the document), the footnote size
   (the dominant size between marker and body), and marker sizes (< about
   0.7 × body). Use ratios, never hard-coded points, so gelato and other PDFs
   work. Group spans into lines by baseline, then lines into paragraphs by
   vertical gap. Keep content-stream `sequence` order within each zone.
2. **Footnote segmentation and relocation.** Zone = footnote-size text.
   Split into items at label markers. Render body markers as `[^m]` and
   append `[^m]: text` definitions after the page body. Then handle
   cross-page continuation. This is expected to be the largest single gain.
3. **Headings** from size rank: largest → `#`, other sizes above body → `##`.
   Watch display type such as the 200 pt "2027" on the cover.
4. **Dehyphenation** at line joins: lowercase letter + "-" at line end
   followed by a lowercase start → join. Keep the hyphen before digits and
   capitals ("Agent-5").
5. **Furniture removal.** Port `stripRepeatedFurniture`
   (`Sources/PdfmdCore/DocumentAssembly.swift`): keys from the top and bottom
   margin bands with digits folded, repeated on at least max(3, pages/3)
   pages. Also drop `artifact_type` spans. This is also what fixes the
   gelato watermark ("Tutti i diritti riservati…" repeats on every page in
   pdf_oxide output).
6. **Gelato checks.** pdf_oxide output letter-spaces display text
   ("a n g e l o c o r v i t t o") and turns credits ("# rafel vilà") into
   headings. Collapse runs of single letters separated by spaces when the
   span geometry shows tracking (`char_spacing` > 0). Add a small
   deterministic test fixture for this; `swift test` rules carry over: no
   network and no local PDFs in `cargo test`.
7. Port `--debug-dir` (per-page JSON: blocks, kinds, bboxes, and the draft,
   like `DebugOutput.swift`).
8. After reaching ≥ 89.57%: delete the Swift tree, then update AGENTS.md
   (the zero-dependency rule becomes "pdf_oxide + listed crates"),
   README.md, the Makefile (`cargo build --release`, install
   `target/release/{pdfmd,pdfmd-bench}` to `~/usr/bin`), `.gitignore`, and
   the baselines list in `Benchmarks/AI2027/README.md` (add a Rust baseline
   entry for each step).

Swift heuristics worth reading for ideas (Vision-specific parts don't
apply): `FootnoteRelocation.swift` (698 lines, native-guided footnote
pairing, page-20 and page-23 regressions), `StructureDedup.swift`,
`ReadingOrder.swift`, `MarkdownRenderer.swift`, and the tests under
`Tests/PdfmdCoreTests/` (e.g. `FootnotePage20RegressionTests`), which are
good sources for Rust regression tests.

## Working rules (from the user)

- Bug fixes: write a failing regression test first, then fix the root cause.
- Don't run formatters, linters, or pre-commit hooks. Never push.
- stdout carries Markdown only. Errors are one line on stderr, with no
  backtraces.
- The benchmark PDFs and `golden.md` stay local and untracked.
- `gelato.md` (untracked) is the old Swift output the user called poor. It
  is not committed.
