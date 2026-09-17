Build a new, production-quality macOS command-line tool for extracting PDFs into clean, faithful Markdown.

This is a greenfield project. Treat this document as the complete specification; do not assume any prior conversation or hidden requirements.

The project should be unusually focused and small. The goal is not to recreate Marker, build a document platform, or create another general-purpose AI utility. The goal is one excellent native command:

```text
pdfmd input.pdf
```

implemented using the document-intelligence capabilities already shipped in macOS 27.

# 1. Core objective

Implement a native Swift CLI whose conceptual pipeline is:

```text
PDFKit
   │
   ├── exact native PDF text + geometry
   │
   └── page rasterization
            │
            ▼
Vision RecognizeDocumentsRequest
            │
            ▼
      canonical Page IR
            │
            ▼
 deterministic Markdown
            │
            ├── ordinary/high-confidence page ──────────────┐
            │                                                │
            └── ambiguous/complex page                       │
                       │                                      │
                       ▼                                      │
             Apple Foundation Models                         │
             + original page image                           │
             + structured extraction                         │
             + Markdown draft                                │
                       │                                      │
                       ▼                                      │
                 fidelity guard                              │
                       │                                      │
                       └──────────────────────┬───────────────┘
                                              ▼
                                         final Markdown
```

The primary workload is large PDFs containing mixtures of:

* born-digital selectable text
* scanned or image-only pages
* text embedded in image-heavy layouts
* multiple columns
* section headings
* footnotes
* lists
* tables
* callouts
* irregular typography
* diagrams or illustrations containing incidental text

The primary objective is **faithful textual extraction and document structure**.

Do not spend scope reproducing arbitrary graphics.

Do not summarize the PDF.

Do not invent text.

Do not describe ordinary illustrations unless their textual content belongs in the document transcription.

# 2. Platform and implementation constraints

Target only:

* macOS 27.0+
* Swift 6.3
* Swift 6 language mode
* Xcode 27 SDK/toolchain
* Swift Package Manager
* Apple Silicon
* Terminal-driven development

Use only Apple/system frameworks and the Swift standard library.

Expected frameworks include:

* Foundation
* PDFKit
* Vision
* FoundationModels
* CoreGraphics

Use CoreText, ImageIO, NaturalLanguage, Accelerate, etc. only if a demonstrated requirement justifies them.

The package must have **zero third-party package dependencies**.

Explicitly do not use:

* swift-argument-parser
* Vapor
* MCP SDKs
* Python
* Node.js
* JavaScript
* PyTorch
* MLX
* llama.cpp
* Ollama
* Poppler
* Tesseract
* SQLite
* Homebrew dependencies
* remote APIs
* cloud OCR
* remote LLM providers
* subprocesses around Apple's `fm` CLI

The release artifact should be a normal native Swift executable.

`Package.swift` should use Swift tools 6.3, Swift 6 language mode, and a macOS 27 deployment target.

Do not add compatibility code for macOS 26 or older.

Do not create an Xcode project unless tooling itself requires temporary metadata. The repository should build from Terminal with SwiftPM.

# 3. Development philosophy

Keep the program small enough that one engineer can understand the entire extraction pipeline.

Prefer:

* immutable value types
* straightforward algorithms
* deterministic behavior where possible
* system frameworks
* explicit data flow
* narrow files
* testable pure functions
* deletion over abstraction

Avoid:

* dependency-injection frameworks
* provider abstractions
* plugin systems
* factories that only produce one type
* service locators
* giant manager objects
* generic "AI engine" architectures
* unnecessary protocols
* configuration systems
* persistence
* daemons
* servers
* feature creep

A protocol is justified when it creates a meaningful testing seam, particularly around Foundation Models.

Do not create abstractions merely because this is Swift.

# 4. Prior research and known landscape

Substantial research has already been done. Do not restart from zero.

The following conclusions should guide implementation.

## 4.1 Marker

Repository:

```text
datalab-to/marker
```

Marker is the important quality reference.

It is a mature document-to-Markdown system with separate fast/balanced paths, native-PDF-text handling, OCR/layout models, table extraction, image extraction, and optional LLM repair.

It demonstrates an important architectural principle:

> use exact/native document information where trustworthy, structured OCR where necessary, and language models as selective repair rather than indiscriminate transcription.

Marker is Python/PyTorch/model-heavy and therefore intentionally not our implementation architecture.

Use it as:

* a quality reference
* a source of pathological document cases
* an optional external comparison during research

Do not make it a build, runtime, or test dependency.

## 4.2 pdf2epub

Repository:

```text
overcuriousity/pdf2epub
```

This project was investigated because it appears to be an intelligent PDF→Markdown/EPUB converter.

Its PDF→Markdown path is fundamentally a wrapper around Marker. It instantiates Marker's `PdfConverter`, receives Markdown/images/metadata, writes them, then optionally converts the result to EPUB.

There is little architectural value for this project beyond demonstrating that Marker is already useful as a conversion primitive.

Do not copy its Python wrapper architecture.

## 4.3 mac-ocr

Repository:

```text
privatenumber/mac-ocr
```

This is one of the strongest references for:

* native macOS Vision usage
* PDF handling
* large multi-page PDF behavior
* page-by-page streaming
* structured `RecognizeDocumentsRequest`
* searchable PDF implementation
* robust CLI behavior

It is Swift and uses only Apple's `swift-argument-parser` dependency.

On recent macOS it can expose:

* transcript
* paragraphs
* tables
* lists
* line geometry
* table-cell ranges

Study its PDF handling and lifecycle carefully.

Do not inherit:

* its Node wrapper
* searchable-PDF scope
* compatibility layers
* CLI breadth
* its argument-parser dependency

Our CLI is small enough to parse arguments directly.

## 4.4 docOCR

Repository:

```text
riddleling/docOCR
```

This is a particularly valuable reference for deterministic `DocumentObservation → Markdown`.

Study its `DocumentOCRService.swift` closely.

Important techniques already demonstrated there include:

* transforming Vision tables into Markdown tables
* escaping `|`
* representing intra-cell line breaks
* converting Vision lists to Markdown lists
* normalizing list markers
* stripping duplicated OCR list markers
* suppressing list blocks that are substantially inside table blocks
* suppressing ordinary paragraphs that are substantially inside table/list regions
* geometric block ordering
* joining OCR-split paragraphs
* handling CJK spacing
* avoiding duplicated structured text

These are useful ideas because `RecognizeDocumentsRequest` can expose the same textual material simultaneously through paragraph containers and through tables/lists.

Do not solve this duplication by asking a language model to clean it afterward.

The deterministic layer should understand the Vision object model correctly.

Do not inherit:

* Vapor
* HTTP serving
* its Swift 5 language mode
* image-only limitations

## 4.5 vision.mcp

Repository:

```text
br3akzero/vision.mcp
```

This is perhaps the closest low-level precursor to the desired deterministic pipeline.

It already uses:

* Swift tools 6.3
* Swift 6 mode
* PDFKit
* page rasterization
* `RecognizeDocumentsRequest`
* extraction of paragraphs
* extraction of lists
* extraction of tables

Its PDF parser is conceptually almost exactly:

```text
PDFDocument
→ render page
→ RecognizeDocumentsRequest
→ structured page result
```

Study this implementation.

It stops before:

* high-quality Markdown reconstruction
* PDF native-text reconciliation
* Foundation Models repair
* the benchmark-driven quality work required here

It also brings in an MCP SDK which we do not want.

## 4.6 mac-local-vision / macvis

Repository:

```text
junmo-kim/mac-local-vision
```

This is useful because it combines in one Swift codebase:

* native Vision
* PDF rasterization
* `RecognizeDocumentsRequest`
* Foundation Models
* macOS 27 multimodal Foundation Models image input
* shared image/PDF loading
* a tiny native binary

Its Foundation Models image plumbing and its structured document OCR are useful references.

However, this project is deliberately **not** our architectural foundation.

Its scope has grown into unrelated capabilities such as:

* barcode scanning
* QR generation
* face grouping
* image classification
* MCP
* HTTP serving
* agent-related functionality

We want a substantially narrower and more deliberate codebase.

Read the relevant pieces; do not fork the project.

## 4.7 PigeonEye

Repository:

```text
adisagar2003/PigeonEye
```

This is another useful modern Swift reference.

It combines:

* PDFKit
* `RecognizeDocumentsRequest`
* Foundation Models

Its Vision path explicitly uses `RecognizeDocumentsRequest` rather than the older line-oriented OCR path.

Its local-model code demonstrates direct in-process use of Foundation Models.

It is an application rather than a PDF→Markdown converter and ultimately dropped Markdown as an export format.

Study implementation details only.

## 4.8 Swift2MD

Repository:

```text
herrkaefer/Swift2MD
```

Despite the name, this delegates conversion to Cloudflare Workers AI.

It is not architecturally relevant because this project must remain fully local.

## 4.9 Osh

Repository:

```text
Hyp4tia/Osh
```

Osh advertises native/offline document-to-Markdown conversion but delegates conversion functionality to Firecrawl AnyDoc.

Again, not the architecture desired here.

## 4.10 Broader search conclusion

Previous research searched GitHub for combinations of:

* PDFKit
* `PDFDocument`
* `RecognizeDocumentsRequest`
* `DocumentObservation`
* FoundationModels
* `LanguageModelSession`
* multimodal Foundation Models
* Markdown rendering
* PDF-to-Markdown tools

There are applications containing combinations of these pieces, but no mature focused CLI was found whose core product is:

```text
PDFKit
→ RecognizeDocumentsRequest
→ FoundationModels visual repair
→ Markdown
```

Treat this project as filling that specific gap.

# 5. Permission to clone reference repositories

You are explicitly permitted and encouraged to clone relevant upstream repositories into a temporary research directory.

For example:

```text
.research/
```

or outside the repository working tree.

Useful commands may include:

```text
gh repo clone privatenumber/mac-ocr
gh repo clone riddleling/docOCR
gh repo clone br3akzero/vision.mcp
gh repo clone junmo-kim/mac-local-vision
gh repo clone adisagar2003/PigeonEye
gh repo clone datalab-to/marker
gh repo clone overcuriousity/pdf2epub
```

You may inspect source, tests, commits, issues, and implementation details.

Do not:

* vendor these repositories
* copy their dependency stacks
* blindly transplant large files
* create runtime dependencies on them
* leave cloned repositories inside the final product tree
* reuse GPL-licensed code in ways incompatible with this project's eventual license

Study algorithms and API usage, then implement the required behavior cleanly in this repository.

Prefer learning from several independent implementations rather than cargo-culting one.

# 6. Verify the actual Xcode 27 SDK first

Before production implementation, inspect the installed SDK.

Do not trust remembered API signatures.

Use:

```text
swift --version
xcodebuild -version
xcrun --sdk macosx --show-sdk-version
xcrun --sdk macosx --show-sdk-path
```

Inspect Swift interfaces and compile tiny disposable probes where needed.

Verify the exact current APIs for at least:

### PDFKit

* `PDFDocument`
* `PDFPage`
* `PDFPage.string`
* `PDFPage.attributedString`
* page bounds
* character/selection geometry
* selections
* text layout information useful for native reconciliation

### Vision

* `RecognizeDocumentsRequest`
* `DocumentObservation`
* document title
* document paragraphs
* lines
* lists
* list items
* markers
* tables
* rows
* columns
* cells
* `rowRange`
* `columnRange`
* bounding regions
* text recognition options

### FoundationModels

* `SystemLanguageModel`
* model availability
* `LanguageModelSession`
* image `Attachment`
* multimodal prompting
* `GenerationOptions`
* deterministic/greedy sampling facilities
* guided generation
* `@Generable`
* context-window behavior
* any current Foundation Models OCR/document tools

The goal of these probes is to establish what the SDK actually supports.

Delete throwaway probes when their findings are incorporated into tests or comments.

# 7. Benchmark-first development

Before optimizing implementation, establish one serious end-to-end benchmark.

The primary golden specimen is:

```text
https://ai-2027.com/ai-2027.pdf
```

This is intentionally a real, substantial, visually rich document rather than a tiny synthetic PDF.

It contains useful challenges including:

* long-form prose
* headings
* footnotes
* side material
* multiple spatial text regions
* diagrams and infographic labels
* typography
* page furniture
* links
* numbers
* punctuation
* image-heavy content

It is therefore a useful integrated test of extraction quality.

## 7.1 Pin the source

The benchmark must be reproducible.

Download the exact PDF once and calculate:

* SHA-256
* byte size
* page count

Store those values in a benchmark manifest.

The benchmark tooling must reject or clearly warn about a source PDF whose SHA-256 does not match the pinned specimen.

Do not silently benchmark a later changed upstream document.

## 7.2 Licensing caution

Before committing either:

* the full source PDF
* a full-text derivative/golden Markdown

to a public repository, verify that doing so is permitted.

If licensing is unclear, keep those large copyrighted artifacts local/untracked.

The repository can instead contain:

* a manifest
* source location
* SHA-256
* benchmark-generation instructions
* scoring code

Do not turn benchmark convenience into an avoidable copyright problem.

# 8. The golden Markdown

Create a frozen authoritative benchmark text:

```text
golden.md
```

for the pinned AI 2027 PDF.

This golden file must be independent of `pdfmd`.

Do not generate it by simply running the implementation under test.

The PDF is the source of truth.

Use several independent signals to curate the gold:

* PDF native text
* PDF geometry
* visual inspection
* existing high-quality extractors such as Marker if useful
* the corresponding AI 2027 website as a reading-order/content cross-check

Important:

The live website has changed after the PDF's original publication.

Therefore:

> when the website and the pinned PDF disagree, the pinned PDF wins.

The golden Markdown should represent the meaningful textual contents of the pinned PDF, not a later website revision.

The benchmark does not need to reproduce arbitrary decorative graphics.

Include:

* headings
* body text
* meaningful lists
* meaningful callouts
* footnote text
* numeric content
* textual material necessary to understand the document

Exclude when clearly decorative/document furniture:

* page numbers
* repeated running headers/footers
* graph-axis clutter
* tiny infographic dashboard labels that are not part of the narrative text
* duplicated visual labels
* purely decorative text

Record ambiguous inclusion decisions in the benchmark README so the gold remains stable.

# 9. Create a raster-only twin benchmark

The born-digital source alone is insufficient.

A converter could obtain an excellent score largely from `PDFPage.string`, which would not meaningfully validate Vision OCR.

Generate:

```text
ai-2027-raster.pdf
```

from the pinned source PDF.

Requirements:

* rasterize every source page at high quality, initially ~300 DPI
* construct a new PDF whose pages contain only those raster images
* preserve page order and approximate page dimensions
* ensure there is **no selectable/native text layer**
* verify programmatically that PDFKit does not expose meaningful native text from it

The raster PDF and original PDF must use the **same `golden.md`**.

This gives two meaningful end-to-end tracks:

```text
born digital:
PDFKit + Vision + reconciliation → Markdown
```

and:

```text
raster only:
Vision + layout reconstruction → Markdown
```

The raster benchmark is the more important test of our OCR/document-understanding pipeline.

# 10. Text-match metric

The principal completion metric is an order-sensitive textual fidelity score against `golden.md`.

Implement the benchmark scorer inside this repository using Swift/system facilities only.

Do not use Python benchmark scripts.

Before comparison, normalize candidate and gold consistently.

Normalization should include:

* Unicode normalization
* ligature normalization
* soft-hyphen removal
* sensible superscript digit normalization where appropriate
* Markdown syntax removal
* Markdown link syntax reduction to visible text where appropriate
* Markdown footnote-marker normalization
* whitespace collapse
* line-wrap normalization
* page-break normalization

Do not normalize away meaningful words, numbers, or punctuation merely to improve the score.

Tokenize into a useful sequence that retains:

* words
* numbers
* meaningful punctuation

Then compute an order-sensitive edit/diff score.

A reasonable conceptual definition is:

```text
match = 1 - edit_cost(candidate, gold) / token_count(gold)
```

Use a deterministic algorithm such as Myers diff or an efficient edit-distance/LCS formulation suitable for a large document.

Report at least:

```text
gold tokens
candidate tokens
matching tokens
deletions
insertions
replacements
text match %
novel-text %
```

Do not hide insertions inside a single flattering aggregate score.

# 11. Benchmark completion gates

The project is not complete until the pinned AI 2027 benchmark satisfies all of these:

## Original born-digital PDF

Target:

```text
>= 99% normalized textual match
```

This should be extremely high because trustworthy PDF native text can preserve exact characters.

A materially lower score indicates problems in:

* native-text reconciliation
* reading order
* block suppression
* footnote handling
* heading logic
* document assembly

## Raster-only PDF

Hard completion target:

```text
>= 95% normalized textual match
```

This is the central project-quality goal.

Hitting >=95% over the full real-world document using only Apple's Vision/document APIs plus selective Foundation Models repair constitutes meaningful success.

## Novel text

For the raster benchmark:

```text
novel-text rate < 1%
```

Do not achieve recall by hallucinating.

## Catastrophic pages

Also compute page-level fidelity where gold-page segmentation can be established reasonably.

There must be no substantive page with catastrophic extraction.

Use approximately:

```text
no substantive page < 85% textual match
```

as a debugging guardrail.

The whole-document score remains authoritative, but a handful of destroyed pages must not be concealed by many easy pages.

# 12. Synthetic correctness fixtures remain necessary

AI 2027 is the quality benchmark, but it does not sufficiently exercise every structure.

Keep a very small generated/checked-in fixture corpus for deterministic correctness.

Cover at least:

1. born-digital single-column prose
2. clear title + paragraphs
3. bullet list
4. numbered list
5. simple table
6. table with a missing cell
7. merged-cell table
8. two-column prose
9. image-only page
10. mixed native + raster page
11. repeated page headers/footers
12. punctuation, URLs and identifiers
13. CJK line joining
14. hard line-wrap hyphenation

Generate fixtures with system APIs where practical.

Do not create a giant test corpus.

# 13. Minimal CLI

Keep the user-facing interface extremely small.

Required forms:

```text
pdfmd INPUT.pdf

pdfmd INPUT.pdf -o OUTPUT.md

pdfmd INPUT.pdf --pages 1,3-7,12

pdfmd INPUT.pdf --debug-dir DIR

pdfmd --help

pdfmd --version
```

Defaults:

* process the entire PDF
* output Markdown to stdout when `-o` is omitted
* diagnostics/progress go only to stderr
* page numbers presented to users are 1-based

No configuration files.

No AI-selection flags.

Specifically do **not** expose:

```text
--ai
--model
--provider
--ocr-engine
--layout-engine
```

Foundation Models are an internal implementation detail.

The tool should simply produce the best Markdown it can using available local macOS capabilities.

If Foundation Models are unavailable, the deterministic pipeline continues.

Do not make normal conversion dependent on Apple Intelligence being enabled.

# 14. Argument parsing

Implement the tiny CLI directly.

Do not add swift-argument-parser.

Support:

* one input PDF
* optional output path
* optional page specification
* optional debug directory
* help/version

Return conventional non-zero exit codes for failures.

Ordinary command errors should be short and useful.

No stack traces.

# 15. Core internal representation

Do not pass loose strings between stages.

Define one compact canonical page IR using only Swift `Sendable` value types.

Conceptually:

```text
Page
  pageNumber
  dimensions
  nativeTextQuality
  blocks[]
  complexitySignals
```

Blocks may include:

```text
title
heading
paragraph
list
table
```

Each block should retain:

* kind
* textual content or structured content
* normalized bounding region
* source evidence

Tables should remain structured internally.

Preserve when available:

* row count
* column count
* row ranges
* column ranges
* cell spans

Do not flatten tables to Markdown until the renderer stage.

All geometry should be transformed immediately into one documented normalized coordinate system.

Do not let PDFKit and Vision coordinate conventions leak throughout the codebase.

# 16. PDFKit stage

Open input using `PDFDocument`.

Reject:

* non-PDF input
* unreadable PDF
* malformed PDF
* locked/encrypted PDF

cleanly in v1.

Password handling is out of scope.

For every selected page, inspect native PDF text before OCR.

Collect useful native evidence such as:

* `PDFPage.string`
* attributed text
* character geometry
* selections
* line grouping
* page bounds
* font/typographic information where reliably available

Native PDF text is valuable because OCR can corrupt exact:

* punctuation
* URLs
* numbers
* identifiers
* accented text
* code
* mathematical characters

But do not blindly trust every nonempty PDF text layer.

Detect obviously broken native text using a small deterministic quality assessment.

Useful evidence may include:

* printable-character ratio
* replacement characters
* private-use Unicode
* implausible control characters
* amount of extracted text
* gross duplication
* geometric sanity
* rough agreement with Vision

Keep this simple.

Do not create a learned classifier.

# 17. Page rasterization

Render each PDF page directly into memory as `CGImage`.

Do not encode an intermediate PNG/JPEG merely to feed Vision.

Begin around:

```text
~216–300 DPI
```

and tune using benchmark evidence.

Choose the lowest resolution that maintains benchmark quality.

Preserve aspect ratio.

Clamp pathological page dimensions if necessary.

Release page bitmaps promptly.

Large documents are a first-class workload.

Never retain all rendered pages simultaneously.

# 18. Vision extraction

Run:

```text
RecognizeDocumentsRequest
```

on rendered pages.

Use the current macOS 27 API rather than older `VNRecognizeTextRequest` unless a specific fallback is proven necessary.

Enable:

* automatic language detection
* language correction

when supported by the actual installed SDK and when benchmark evidence supports doing so.

Map Vision results into the canonical Page IR.

Extract at minimum:

* document title
* paragraphs
* lines as needed
* lists
* list markers
* tables
* table cells
* row/column ranges
* bounding regions

Preserve enough evidence for later reconciliation and complexity analysis.

# 19. Structured-text deduplication

This is a crucial deterministic stage.

Vision may surface table/list text simultaneously in:

* `document.paragraphs`
* table cell content
* list item content

Do not output those copies multiple times.

Use geometry.

A strong baseline, as demonstrated in docOCR, is:

1. build table blocks
2. build list blocks
3. suppress list blocks substantially contained inside tables
4. build paragraph blocks
5. suppress paragraphs substantially contained inside tables or surviving lists
6. sort the remaining structural blocks in reading order

Make containment thresholds explicit and tested.

Do not use Foundation Models to repair duplicates that the Vision object hierarchy already explains deterministically.

# 20. Reading order

Reading order is one of the core quality problems.

Do not blindly trust container array order.

Implement a small geometry-based deterministic reading-order algorithm.

It should handle:

* ordinary single-column pages
* headings spanning width
* side-by-side blocks
* common two-column layouts
* footnotes
* tables interleaved with prose

A useful primitive is:

* blocks substantially sharing a horizontal band order left→right
* otherwise order top→bottom

But a real two-column page must not become:

```text
left row 1
right row 1
left row 2
right row 2
```

if the document intends:

```text
left column
then right column
```

Detect obvious column structure from block geometry.

Do not build a giant document-layout engine.

When deterministic evidence is genuinely ambiguous, record that ambiguity as a complexity signal for selective Foundation Models repair.

# 21. Native-text reconciliation

Vision should primarily provide:

* document structure
* regions
* reading order evidence

It should not unnecessarily replace trustworthy born-digital text.

Spatially reconcile Vision blocks with native PDF text.

Where:

* the native layer is trustworthy
* geometry strongly corresponds
* text refers to the same region

prefer native characters.

Use Vision text where:

* native text is absent
* native text is broken
* the page is raster-only
* reconciliation confidence is poor

Keep matching conservative.

A wrong native/Vision association is worse than accepting Vision OCR.

Benchmark this heavily on:

* URLs
* punctuation
* numbers
* names
* unusual characters

# 22. Deterministic Markdown renderer

Every page must produce useful Markdown without Foundation Models.

Implement and test this before adding AI repair.

## Paragraphs

* collapse hard line wraps
* preserve genuine paragraph boundaries
* repair line-break hyphenation only when confidence is high
* do not incorrectly insert spaces between CJK characters
* preserve punctuation

## Lists

* normalize ordinary bullets to `-`
* retain ordered numbering where meaningful
* strip OCR marker duplication
* flatten unsupported exotic nesting conservatively
* never duplicate list items as paragraphs

## Tables

Simple rectangular tables should become Markdown pipe tables.

Requirements:

* escape `|`
* preserve empty cells
* do not invent cell contents
* use `<br>` for meaningful internal line breaks
* preserve all readable cell text

For merged or structurally irregular tables:

* preserve textual content
* do not silently drop spanning cells
* mark the page as structurally complex
* allow the repair stage to improve presentation

Markdown cannot represent arbitrary row/column spans perfectly. Fidelity matters more than pretending otherwise.

## Headings

Vision provides title information but not a perfect Markdown heading hierarchy.

Use conservative evidence such as:

* document title
* native PDF font size
* font weight
* vertical whitespace
* full-width positioning
* short isolated text

to infer obvious headings.

Do not invent heading hierarchy aggressively.

# 23. Footnotes

AI 2027 makes footnote handling important.

Recognize likely footnotes using a combination of:

* bottom-of-page position
* small typography/native font size
* superscript markers
* association with nearby reference markers
* repeated footnote-like layout

The desired final Markdown may use standard Markdown footnote syntax where the mapping is clear.

Do not:

* lose footnote text
* insert a footnote into the middle of the main paragraph because of geometry
* mistake page furniture for footnotes

When exact marker association is ambiguous, preserving footnote text cleanly is more important than inventing a false mapping.

# 24. Repeated headers and footers

After lightweight Page IR exists for multiple pages, detect recurring page furniture.

Compare normalized text in approximately the same:

* top margin region
* bottom margin region

across many pages.

Remove only high-confidence repetitions.

Examples:

* running section title
* repeating document title
* page number

Do not delete one-off titles merely because they occur near the top of a page.

This should remain a small deterministic algorithm.

# 25. Foundation Models are a repair stage, not OCR

macOS 27 Foundation Models can reason over images.

Use that capability selectively.

Do **not** use Foundation Models as the primary OCR engine.

The primary extraction path is:

```text
PDFKit + RecognizeDocumentsRequest
```

because those provide:

* exact native text
* paragraphs
* lists
* tables
* geometry
* deterministic behavior

Foundation Models should be used only where semantic/visual reasoning provides real additional value.

Do not replace `RecognizeDocumentsRequest` with Foundation Models `OCRTool`.

Do not OCR the entire document twice merely because the API exists.

# 26. Internal Foundation Models behavior

Foundation Models should be automatic and invisible to the user.

At startup or first potential use, inspect:

```text
SystemLanguageModel.default.availability
```

If unavailable:

* emit at most one concise warning to stderr if useful
* continue deterministically
* do not fail ordinary conversion

If available, route only sufficiently complex/ambiguous pages.

Useful complexity signals may include:

* likely multi-column reading-order ambiguity
* conflicting native and Vision ordering
* significant Vision/native disagreement
* irregular merged-cell tables
* uncertain heading hierarchy
* fragmented OCR
* unusually dense overlapping text regions
* poor deterministic extraction-quality metrics

Keep routing transparent.

Prefer a handful of named signals over a mysterious weighted heuristic.

Simple prose pages should not invoke the model.

# 27. Multimodal repair prompt

For a page selected for repair, provide the Foundation Model with:

1. the original rendered page image
2. a compact representation of structured Page IR
3. the deterministic Markdown draft
4. a short strict reconstruction instruction

The instructions should say, in substance:

```text
You are reconstructing Markdown from a document page.

Preserve the source text.

Do not summarize.

Do not explain.

Do not add facts or prose.

Do not silently omit readable textual content.

Use the page image only to resolve layout, reading order,
hierarchy, table/list structure, and obvious OCR errors.

Prefer exact supplied native text over guessing characters
from the image.

Return only reconstructed Markdown for this page.
```

Keep prompts compact.

Apple's on-device model has a limited context budget.

Do not dump irrelevant metadata into the model.

# 28. Foundation Models sessions

Do not maintain one giant model transcript across a large PDF.

Use a fresh or deliberately bounded session for each repaired page.

This avoids:

* context growth
* cross-page contamination
* accidental model memory
* runaway context-window usage

Use deterministic/greedy generation when available.

Use guided generation only when it improves reliability.

A minimal result schema such as:

```text
RepairedPage {
    markdown: String
}
```

is sufficient.

Do not create elaborate AI schemas merely because `@Generable` exists.

# 29. Fidelity guard

Never accept Foundation Models output blindly.

Implement a deterministic fidelity validator.

Compare:

* deterministic extracted text
* repaired Markdown projected back to plain text

after tolerant normalization.

Reject repairs with:

* substantial novel text
* catastrophic omission
* empty output
* obvious repetition
* suspicious expansion

Formatting and legitimate text ordering changes must remain possible.

Do not require byte identity.

If a repair fails validation:

* discard it
* retain deterministic Markdown
* record the reason in debug output

Do not recursively ask the model to fix its own failed answer.

One AI repair attempt per page is sufficient for v1.

# 30. Large-document processing

Large PDFs must use bounded memory.

Do not retain:

* all rendered page images
* all PDFPage objects
* giant model transcripts

A good initial architecture is:

### Pass 1

For each selected page:

```text
PDFKit native extraction
→ render page
→ Vision structured extraction
→ reconciliation
→ Page IR
→ release bitmap
```

Retain only lightweight Page IR.

### Pass 2

Use Page IR across the document for:

* repeated header/footer detection
* page-level complexity analysis
* document assembly metadata

### Pass 3

Render deterministic Markdown.

### Pass 4

Only for pages chosen for Foundation Models repair:

```text
re-render page
→ model repair
→ fidelity validation
→ release bitmap
```

Re-rendering a minority of pages is preferable to holding hundreds of large images in memory.

# 31. Concurrency

Start serially.

Do not begin with:

* worker pools
* task groups
* semaphores
* custom scheduling
* dozens of concurrent Vision requests

First establish correctness and benchmark quality.

Only introduce bounded page concurrency after profiling proves it produces a meaningful throughput improvement without:

* degrading Vision stability
* increasing peak memory badly
* complicating PDFKit isolation

If PDFDocument/PDFPage access eventually crosses concurrency domains, isolate it behind an actor.

Do not scatter:

```text
@unchecked Sendable
```

over non-Sendable framework types.

# 32. Debug output

Support:

```text
--debug-dir DIR
```

When enabled, write useful diagnostic artifacts.

For example:

```text
DIR/
  document.json
  page-0001/
    native.txt
    vision.json
    reconciled.json
    deterministic.md
    repaired.md
    metrics.json
```

Only save raster page images when there is a demonstrated debugging need.

Do not make debug mode reproduce a huge PDF as hundreds of giant images by default.

`Codable` is appropriate for debug structures.

The production path must not depend on debug serialization.

# 33. Output handling

When no `-o` is supplied:

```text
stdout = Markdown only
stderr = diagnostics/progress
```

This invariant matters for shell use.

When writing to a file:

* write UTF-8
* use a temporary sibling file
* atomically replace the final path after successful conversion

Avoid leaving a deceptively complete but truncated output after failure.

# 34. Error handling

Handle cleanly:

* missing arguments
* invalid flags
* nonexistent input
* non-PDF input
* malformed PDF
* encrypted/locked PDF
* malformed page specification
* page render failure
* Vision failure
* output write failure
* Foundation Models unavailable
* Foundation Models context overflow
* Foundation Models inference failure

Foundation Models failure should generally degrade to deterministic output.

If Vision fails but native text is strong, native extraction may provide a fallback.

If neither source is trustworthy, fail clearly rather than fabricate content.

No normal error should print a Swift backtrace.

# 35. Project structure

Keep the source tree small.

A reasonable starting point is:

```text
Package.swift

Sources/pdfmd/
  main.swift
  CLI.swift
  PDFSource.swift
  Geometry.swift
  PageModel.swift
  VisionExtractor.swift
  NativeReconciler.swift
  ReadingOrder.swift
  MarkdownRenderer.swift
  FoundationRepairer.swift
  FidelityValidator.swift
  Pipeline.swift

Tests/pdfmdTests/
  ...

Benchmarks/
  AI2027/
    README.md
    manifest.json
```

Do not follow this mechanically if fewer files are clearer.

Conversely, do not allow one 2,000-line manager file.

Boundaries should correspond to actual responsibilities.

# 36. Testing requirements

Use Swift Testing:

```text
import Testing
```

unless the installed Swift 6.3 toolchain exposes a concrete blocker.

The normal test suite must require:

* no network
* no external binaries
* no Foundation Models availability
* no Homebrew software

Test deterministic logic aggressively.

## CLI tests

Cover:

* page-list parsing
* page ranges
* duplicates
* invalid ranges
* output behavior
* stderr/stdout separation
* bad input

## Geometry tests

Cover:

* coordinate normalization
* containment
* overlap
* table/list paragraph suppression
* horizontal-band sorting
* two-column sorting
* footnote placement

## Markdown tests

Cover:

* paragraphs
* hard wraps
* hyphenation
* CJK joining
* bullets
* numbered lists
* list-marker stripping
* simple table
* pipe escaping
* multiline cells
* missing cells
* merged-cell degradation

## Native reconciliation tests

Cover:

* exact native text preferred when good
* OCR used when native text is garbage
* punctuation preservation
* URL preservation
* numeric preservation
* mismatched regions do not get merged
* duplicate content is not emitted

## Header/footer tests

Cover:

* recurring header removed
* recurring footer removed
* page numbers removed
* unique first-page title retained

## Complexity routing tests

Cover:

* simple prose does not request AI repair
* clear columns can trigger it
* irregular tables can trigger it
* severe disagreement can trigger it

## Fidelity-validator tests

Cover:

* formatting-only changes accepted
* reordered faithful text accepted
* hallucinated paragraph rejected
* large omission rejected
* duplicate model output rejected
* empty repair rejected

Use a tiny fake repairer/model seam.

Do not mock the whole program.

# 37. Foundation Models integration tests

Real model tests must be opt-in.

The ordinary:

```text
swift test
```

must not invoke Apple Intelligence.

Use an environment variable or explicit benchmark target for the real model smoke test.

The real smoke test should demonstrate:

* Foundation Models availability detection
* page image attachment
* successful multimodal response
* actual visual/layout correction
* fidelity validation

Do not make CI depend on nondeterministic model inference.

# 38. AI 2027 benchmark command

Provide a first-class benchmark invocation.

The exact CLI may be an executable target or an internal benchmark mode, but do not pollute the normal `pdfmd --help`.

A reasonable development command might be:

```text
swift run pdfmd-bench ai2027
```

or an equivalent dedicated benchmark target.

It should:

1. validate benchmark source hash
2. run conversion on original PDF
3. run conversion on raster PDF
4. normalize the generated Markdown
5. compare against golden
6. report metrics
7. fail with non-zero status when completion thresholds are missed

Example report:

```text
AI 2027 — born digital

text match:      99.42%
novel text:       0.08%
deletions:          112
insertions:           19
replacements:         34

AI 2027 — raster

text match:      96.17%
novel text:       0.42%
worst page:      89.13%

PASS
```

Do not hide failures behind averaged or rounded vanity numbers.

# 39. Performance measurement

Quality is first, but record performance.

For the benchmark report, measure at least:

* wall-clock time
* pages processed
* pages sent to Foundation Models
* Vision time if easy to collect
* Foundation Models repair time if easy to collect

Use system tooling to inspect peak memory during development.

Do not build a custom profiler.

The primary performance objective is:

> process large documents with bounded memory and acceptable local throughput.

Do not sacrifice extraction quality to win microbenchmarks.

# 40. Baselines

Before heavy optimization, measure several useful baselines on AI 2027:

### Baseline A

```text
PDFPage.string
```

only.

### Baseline B

```text
RecognizeDocumentsRequest
```

only.

### Baseline C

```text
Vision + deterministic Markdown
```

### Baseline D

```text
Vision + native PDF reconciliation
```

### Final

```text
Vision + native reconciliation + selective Foundation Models repair
```

Record these scores.

This will reveal which parts of the pipeline actually improve quality.

Do not keep architectural complexity that fails to move the benchmark materially.

# 41. Benchmark-driven development rule

The AI 2027 benchmark is not something to run only at the end.

Use it continuously.

When a change is intended to improve extraction:

1. identify the failing pages
2. inspect debug artifacts
3. understand whether the failure is:

   * PDF native extraction
   * Vision recognition
   * geometry
   * reading order
   * duplication
   * Markdown rendering
   * footnote handling
   * AI routing
   * model repair
4. fix the correct stage
5. rerun the relevant pages
6. rerun the full benchmark periodically

Do not respond to every bad page by expanding the Foundation Models prompt.

If a deterministic bug exists, fix the deterministic bug.

# 42. Quality versus code-size discipline

The benchmark target is intentionally hard.

Do not interpret "minimal" as "naïve."

It is acceptable to write careful deterministic logic for:

* reading order
* native/Vision alignment
* table reconstruction
* footnotes
* repeated furniture

when it materially improves correctness.

But require evidence before adding large subsystems.

A useful heuristic:

> if a new abstraction or heuristic cannot be tied to a real failing fixture or benchmark page, do not add it yet.

# 43. Swift 6 requirements

Compile cleanly under Swift 6 strict concurrency.

Prefer:

* `struct`
* `enum`
* `let`
* `Sendable`
* actors only for genuinely shared mutable/non-Sendable state

Do not suppress compiler diagnostics casually.

Avoid:

* `try!`
* force unwraps in production extraction code
* broad `@unchecked Sendable`
* global mutable singletons

If an unsafe concurrency escape hatch is genuinely unavoidable because of an Apple framework boundary, isolate it tightly and explain the invariant in a short comment.

# 44. Source quality

Code should look deliberately engineered.

Avoid common generated-code pathologies:

* enormous comments explaining obvious syntax
* defensive wrappers around impossible states
* needless "manager/service/provider/factory" layering
* repeated utility functions
* duplicate representations of the same concept
* feature stubs
* speculative extension points
* excessive logging
* placeholder abstractions
* giant README prose

Comments should explain:

* non-obvious Vision quirks
* coordinate transforms
* table/list containment rules
* Foundation Models API constraints
* benchmark-driven decisions
* concurrency invariants

# 45. Explicitly out of scope

Do not implement:

* GUI
* SwiftUI
* Finder extension
* Quick Look
* searchable PDF generation
* PDF editing
* QR codes
* barcodes
* face recognition
* image classification
* OCR server
* HTTP server
* REST
* MCP
* agents
* agent skills
* RAG
* embeddings
* vector databases
* databases of any kind
* EPUB
* DOCX
* PPTX
* spreadsheets
* arbitrary image description
* chat
* remote LLM providers
* provider-selection abstraction
* Core ML model downloads
* custom VLMs
* Private Cloud Compute
* plugins
* background daemons
* filesystem watchers
* telemetry
* auto-update
* notarization/signing automation
* GitHub Actions

This is a PDF→Markdown command-line program.

Nothing more.

# 46. Build and development commands

Everything must work from Terminal.

Expected commands include:

```text
swift --version

xcodebuild -version

xcrun --sdk macosx --show-sdk-version

swift package dump-package

swift build

swift test

swift build -c release

.build/release/pdfmd --help

.build/release/pdfmd sample.pdf
```

Do not require opening Xcode.

# 47. README

Write a concise README.

Include:

* what `pdfmd` does
* macOS 27+ requirement
* build instructions
* usage
* local/privacy guarantee
* short architecture explanation
* Foundation Models behavior
* benchmark methodology
* known limitations

Explicitly state:

> PDF content never leaves the Mac.

Do not write marketing copy.

Do not fill the README with badges.

# 48. Implementation order

Follow this sequence.

## Phase 0 — research and benchmark establishment

Before production implementation:

1. inspect Xcode 27 SDK APIs
2. clone relevant reference repositories
3. inspect their focused implementation pieces
4. pin AI 2027 PDF
5. establish benchmark manifest
6. establish independent golden Markdown
7. generate raster-only twin
8. implement benchmark normalization/scoring
9. record simple PDFKit and Vision baselines

This phase prevents optimizing against vague impressions.

## Phase 1 — deterministic extraction

Build:

```text
PDFKit
→ page rendering
→ RecognizeDocumentsRequest
→ canonical Page IR
→ reading order
→ structural deduplication
→ Markdown
```

Make synthetic tests pass.

Run AI 2027.

## Phase 2 — native reconciliation

Add:

```text
PDFKit exact text/geometry
→ spatial reconciliation with Vision
```

Measure the original-PDF score improvement.

Target near-perfect born-digital textual fidelity.

## Phase 3 — document-level cleanup

Add only benchmark-justified logic for:

* repeated headers/footers
* footnotes
* heading inference
* column behavior

Continue measuring.

## Phase 4 — selective Foundation Models repair

Only after deterministic extraction is already respectable:

1. add complexity routing
2. attach the original page image
3. provide compact Page IR + deterministic Markdown
4. perform bounded repair
5. validate fidelity
6. fall back when repair is poor

Measure whether this actually improves the raster benchmark.

If Foundation Models make a class of pages worse, do not route that class to them.

## Phase 5 — cleanup and optimization

Once the benchmark target is reached:

* delete dead experiments
* reduce abstractions
* improve memory lifetime
* profile obvious bottlenecks
* tighten README
* run all completion checks

# 49. Completion criteria

Do not call the project complete until all of the following are true.

## Build

1. `Package.swift` uses Swift tools 6.3.
2. Deployment target is macOS 27+.
3. There are zero package dependencies.
4. `swift build` succeeds.
5. `swift build -c release` succeeds.
6. `swift test` succeeds.
7. Swift 6 concurrency diagnostics are properly resolved.

## CLI

8. `pdfmd --help` is concise.
9. `pdfmd INPUT.pdf` emits Markdown.
10. stdout is clean Markdown only.
11. `-o` works atomically.
12. `--pages` works.
13. `--debug-dir` works.
14. No AI/provider-selection CLI flags exist.

## Deterministic extraction

15. Born-digital PDF extraction works.
16. Image-only PDF extraction works through Vision.
17. Lists do not duplicate paragraph text.
18. Tables do not duplicate cell text.
19. Two-column fixture reads sensibly.
20. Native punctuation/numbers/URLs survive reconciliation.
21. Header/footer removal does not delete genuine content.
22. Large documents do not retain all page rasters.

## Foundation Models

23. Normal operation does not require Apple Intelligence.
24. Foundation Models are used only selectively.
25. Foundation Models receive the actual page image.
26. Model failures fall back cleanly.
27. Fidelity validation rejects fabricated text.
28. No network requests occur.

## AI 2027 benchmark

29. Source PDF is SHA-256 pinned.
30. Raster twin contains no meaningful native text layer.
31. Original and raster benchmark against the same frozen gold.
32. Born-digital normalized text match is >=99%.
33. Raster-only normalized text match is >=95%.
34. Raster novel-text rate is <1%.
35. No substantive benchmark page is catastrophically bad; approximately >=85% per-page floor.
36. Benchmark runner returns non-zero status when thresholds are missed.
37. Baseline and final scores are documented.

## Scope

38. No GUI.
39. No server.
40. No MCP.
41. No database.
42. No third-party OCR/model stack.
43. No unrelated Vision utilities.
44. No remote providers.
45. No feature outside this specification has crept in.

# 50. Final engineering standard

The objective is not merely to make something that compiles.

The final program should demonstrate that a deliberately small Swift executable can exploit:

```text
PDFKit
+ Vision RecognizeDocumentsRequest
+ Apple Foundation Models
```

to approach modern document-to-Markdown quality without shipping:

* Python
* PyTorch
* custom OCR models
* VLM weights
* servers
* dependency ecosystems

The benchmark is the arbiter.

Do not declare success based on a few visually inspected pages.

The central success criterion is:

> The raster-only pinned AI 2027 PDF achieves at least 95% normalized ordered textual fidelity against an independently frozen golden Markdown reference, with less than 1% novel text, while the entire implementation remains a focused zero-third-party-dependency Swift 6.3 macOS 27+ CLI.

Aim for the smallest implementation that genuinely meets that standard.
