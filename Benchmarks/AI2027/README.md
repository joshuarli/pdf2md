# AI 2027 benchmark

End-to-end quality gate (plan.md sections 7-11). The pinned source PDF and
the frozen golden Markdown stay **local and untracked** — do not commit them
until licensing is verified (plan.md section 7.2). The repository carries
only `manifest.json`, the scoring code (`PdfmdCore`), and this note.

## Files (local only, gitignored)

```text
Benchmarks/AI2027/
  ai-2027.pdf          pinned source (ai-2027.com/ai-2027.pdf at manifest SHA-256)
  ai-2027-raster.pdf   raster-only twin: same pages as images, no text layer
  golden.md            frozen independent transcription of the pinned PDF
  manifest.json        SHA-256, sizes, thresholds (committed)
```

## Setup

1. Download the source PDF and check it against the manifest:
   `shasum -a 256 ai-2027.pdf` must match `manifest.json`.
2. Generate the raster twin (helper in `PDFSource.buildRasterOnlyTwin`,
   ~300 DPI) and verify `twinHasNativeText` is false.
3. Curate `golden.md` independently of `pdfmd`: PDF native text, geometry,
   visual inspection, and high-quality extractors as signals — never the
   tool's own output. When the live website and the pinned PDF disagree,
   the pinned PDF wins. Record ambiguous inclusion calls here.

## Run

```bash
swift run pdfmd-bench ai2027 [--dir Benchmarks/AI2027] [--repair]
```

Reports born-digital and raster text-match plus novel-text rates, the worst
page per track (pages with >=20 aligned tokens only), and exits non-zero when
the gates miss: >=99% born-digital, >=95% raster with <1% novel text, and no
substantive raster page below ~85% (plan.md section 11 guardrail).

## Baselines (record here as they land)

- A: `PDFPage.string` only — 93.06% match / 4.7% novel (raw native join vs
  gold; the gap is the curation delta: footnote relocation, dropped running
  heads, rebuilt tables, hyphen joins)
- B: `RecognizeDocumentsRequest` only — _pending_
- C: Vision + deterministic Markdown (pre-line reconciliation) — 71.45%
  born / 71.72% raster, 14.7% / 14.3% novel (`results-deterministic/`)
- D: + native line-level reconciliation — 89.13% born / 85.66% raster, 5.3%
  / 7.29% novel; worst page 70.3% (page 50, a chart whose title/axis text
  Vision reads as prose — data-point labels misread as a list are now
  suppressed, but the chart's own title paragraph and a garbled caption
  line are not) for born, 54.6% (page 4, a raster page whose garbled
  footnote markers `relocateFootnotes`'s geometric fallback can't pair) for
  raster. Both tracks still miss the >=99%/>=95% gates; still in progress —
  see plan.md section 51 for the live punch list and hill-climbing method.
- E: + text-only FM repair (macOS 26) — 71.17% born / 71.72% raster (stale,
  pre-D); repair changed nothing measurable and cost 15x wall-clock when
  last measured against baseline C. Disabled by default until re-measured
  against D — pass `--repair` to `pdfmd-bench ai2027` to re-measure.
- Final: + selective multimodal repair (macOS 27+) — _blocked on Xcode 27_

Bugs found and fixed on the way to D (all with regression tests): a greedy
footnote-body span match could anchor on a single spurious common-word hit
in an unrelated intervening paragraph and blank everything between it and
the real body (`FootnoteRelocation.longestDenseRun`); the same scan's
window was too narrow to reach a margin-column body separated from its
main-column reference by the rest of the column; two footnotes opening
with near-identical phrasing could steal each other's leading words
(`longestOrderedMatchCount`-based coverage recheck after a block-floor
snap); `isOrphanPosition` compared a next-token's capitalization against
an already-lowercased copy of itself, so it could never fire; a genuine
sentence's line-wrap tail stranded in a tiny box was suppressed as OCR
confetti (`suppressFragments` now exempts `.reconciled`-source blocks);
`reconcileParagraphs` — a fully-tested native/Vision title-and-heading
reconciler with a lenient threshold built for exactly this — was never
wired into `Pipeline`, so severely garbled display type never got
corrected at all; `fontLines` split the page's whole linearized
`attributedString` on newlines rather than asking each geometric line
(`selectionsByLine`) for its own font, so a two-column page's last
main-column line and its margin footnote's first line could share one
"line" in that flat string and inherit the main column's body-sized font,
sinking the footnote below `nativeFootnoteItems`'s size gate entirely; and
a chart's data-point labels, OCR'd as a short bullet list, are confetti by
the same area/token measure as a misread caption, but `suppressFragments`
exempted every list unconditionally.

First pipeline measurement (deterministic, pre-footnote-relocation):
77.46% match / 17.3% novel, 44,213/45,328 gold tokens matched. The penalty
was almost entirely insertions (9.1k: inline footnote markers, running-head
residue, OCR confetti, sidebar duplication) — text recall was already 97.5%.

The 71.45% stage that followed is an order regression, not a recall one:
side-by-side layout pages interleave margin notes into body prose
(`ReadingOrder.splitColumns` cannot split pages whose margin blocks do not
form a clean gutter), and whole-page native reconciliation was too coarse.
Line-level native reconciliation is the current fix under measurement.

## Ambiguous gold decisions

All resolved in favor of the pinned PDF (visual render wins over the native
stream when they disagree):

- Running heads (section title repeated at the top of each page, incl.
  two-line wraps like Appendix J) are dropped; the first occurrence stands
  as a `##` heading. 51 dropped.
- Display type (>=13pt) always becomes a `##` heading, including wrapped
  titles ("Superhuman Ad- / vice" joins to "Advice"). Parts ("Race ending",
  "Slowdown ending", "Appendices") and the foreword title ("AI 2027") too.
- Footnotes relocate to page end as `[^marker]:` definitions; body keeps
  `[^marker]` references at the marker position. 175 definitions. Numbers,
  `*`, `†`, `‡` all kept verbatim. Markers that float to the next line
  ("229 Someone") or fuse ("7 7 We consider") are reattached by pairing.
- A footnote body living in the margin (e.g. marker 29, "1 is dealing with
  whatever crisis...") is still a footnote: relocated, not inlined.
- Margin notes without markers and chart/datum fragments with no body
  pairing (e.g. "5 GW of AI power draw") stay inline, verbatim.
- Vector-chart titles/axes expose no native text and are excluded as
  furniture; figure captions ("Visualization of IDA from Ord, 2025.",
  "(Figure from: FlexHEG Report)") are kept as paragraphs.
- The Appendix J milestone table is a hand-built Markdown pipe table.
- Transcribe warts verbatim: superscript loss ("1024" for 10^24, "109"
  for 10^9 — the scorer's superscript normalization makes these match OCR
  either way) and the literal "$ 10^8 ^{15} % = 4 ^{22} $" line, which both
  native text and the render agree on.
- Hyphen-breaks join on lowercase–lowercase only; verified keep-hyphen
  compounds (non-expert, under-resourced, mega-datacenter, ever-more-aligned,
  high-priority, long-run, high-level, commander-in-chief, DeepCent,
  OpenBrain, RE-Bench, 2024-equivalent) fixed by hand.
- Cross-page footnote continuation (p20 "do—because it helps...") is appended
  to p19's last footnote definition. (Open: applied by hand; see below.)
- Green margin pull-quotes duplicating body/footnote text are excluded as
  duplicated visual labels.
- The document's final paragraph ("...if they could sketch out a ten-page
  scenario...") is rejoined across the p70/p71 boundary.
- Website cross-check was not needed: the PDF is self-consistent throughout;
  per the spec the PDF would win any disagreement anyway.

## Open gold issues (fix before freezing)

- The curation script was a one-off under `/tmp` and is gone. The frozen
  `golden.md` plus this README are the durable artifacts: `golden.md` is
  final (hand fixes for the Appendix J table, keep-hyphen compounds, the
  p20 footnote continuation, and the p70/p71 tail join are already applied
  in it). Do not regenerate it from a curation script; edit it directly
  and record every change above.
