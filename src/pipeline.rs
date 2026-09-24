//! Conversion pipeline: pdf_oxide extraction → per-page Markdown.

use std::fmt;
use std::path::Path;

use pdf_oxide::PdfDocument;

use crate::page::{FontProfile, PageContent, PageDebug, append_line, assemble_page, strip_document_furniture};

const STATUS_CARD_REGION: [f64; 4] = [0.64, 0.0, 0.36, 1.0];

#[derive(Debug)]
pub enum ConvertError {
    Open { path: String, reason: String },
    PageOutOfRange { page: usize, page_count: usize },
    Extract { page: usize, reason: String },
    Ocr { page: usize, reason: String },
}

impl fmt::Display for ConvertError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Open { path, reason } => write!(f, "pdfmd: cannot open {path}: {reason}"),
            Self::PageOutOfRange { page, page_count } => {
                write!(f, "pdfmd: page {page} is out of range (document has {page_count} pages)")
            }
            Self::Extract { page, reason } => write!(f, "pdfmd: page {page}: {reason}"),
            Self::Ocr { page, reason } => write!(f, "pdfmd: page {page}: OCR failed: {reason}"),
        }
    }
}

impl std::error::Error for ConvertError {}

/// One converted page. `markdown` is the page's final draft; the document
/// is these drafts joined by blank lines.
#[derive(Debug, Clone)]
pub struct PageDraft {
    pub page_number: usize,
    pub markdown: String,
}

#[derive(Debug, Clone)]
pub struct Conversion {
    pub pages: Vec<PageDraft>,
    pub debug_pages: Option<Vec<PageDebug>>,
    #[cfg(target_os = "macos")]
    pub visual_pages: Vec<crate::ocr::TranscriptPage>,
}

impl Conversion {
    pub fn markdown(&self) -> String {
        let joined = self.pages.iter().map(|p| p.markdown.trim()).filter(|m| !m.is_empty()).collect::<Vec<_>>();
        let mut markdown = joined.join("\n\n") + "\n";
        #[cfg(target_os = "macos")]
        {
            let appendix = crate::ocr::render_appendix(&self.visual_pages);
            if !appendix.is_empty() {
                markdown.push('\n');
                markdown.push_str(&appendix);
            }
        }
        markdown
    }
}

/// Convert `pages` (1-based; `None` = whole document) of the PDF at `path`.
pub fn convert(path: &Path, pages: Option<&[usize]>) -> Result<Conversion, ConvertError> {
    convert_with_debug(path, pages, false)
}

/// Convert the document and retain per-page diagnostics when requested.
pub fn convert_with_debug(
    path: &Path,
    pages: Option<&[usize]>,
    collect_debug: bool,
) -> Result<Conversion, ConvertError> {
    let doc = PdfDocument::open(path)
        .map_err(|e| ConvertError::Open { path: path.display().to_string(), reason: e.to_string() })?;
    let page_count = doc
        .page_count()
        .map_err(|e| ConvertError::Open { path: path.display().to_string(), reason: e.to_string() })?;
    let requested: Vec<usize> = match pages {
        Some(pages) => {
            if let Some(&page) = pages.iter().find(|&&p| p == 0 || p > page_count) {
                return Err(ConvertError::PageOutOfRange { page, page_count });
            }
            pages.to_vec()
        }
        None => (1..=page_count).collect(),
    };
    let mut spans_by_page = Vec::with_capacity(page_count);
    let mut media_boxes = Vec::with_capacity(page_count);
    for page_number in 1..=page_count {
        let media_box = doc
            .get_page_media_box(page_number - 1)
            .map_err(|e| ConvertError::Extract { page: page_number, reason: e.to_string() })?;
        let spans = doc
            .extract_spans(page_number - 1)
            .map_err(|e| ConvertError::Extract { page: page_number, reason: e.to_string() })?;
        media_boxes.push(media_box);
        spans_by_page.push(spans);
    }

    let font_profile = FontProfile::infer(&spans_by_page);
    strip_document_furniture(&mut spans_by_page, &media_boxes, &font_profile);
    let mut page_contents: Vec<PageContent> = spans_by_page
        .into_iter()
        .zip(media_boxes.iter().copied())
        .map(|(spans, media_box)| assemble_page(spans, font_profile, media_box))
        .collect();
    for page_index in 0..page_contents.len() {
        let continuations = std::mem::take(&mut page_contents[page_index].footnote_continuations);
        if continuations.is_empty() {
            continue;
        }
        let destination = page_contents[..page_index]
            .iter_mut()
            .rev()
            .find_map(|page| page.footnotes.last_mut());
        if let Some(definition) = destination {
            for line in continuations {
                append_line(&mut definition.text, &line);
            }
        } else {
            page_contents[page_index].paragraphs.extend(continuations);
        }
    }

    #[cfg(target_os = "macos")]
    let visual_pages = recognize_visual_pages(&doc, &requested, &page_contents)?;

    let mut drafts = Vec::with_capacity(requested.len());
    let mut debug_pages = collect_debug.then(|| Vec::with_capacity(requested.len()));
    for page_number in requested {
        let markdown = page_contents[page_number - 1].markdown();
        if let Some(debug) = &mut debug_pages {
            debug.push(page_contents[page_number - 1].debug_page(page_number, markdown.clone()));
        }
        drafts.push(PageDraft { page_number, markdown });
    }
    Ok(Conversion {
        pages: drafts,
        debug_pages,
        #[cfg(target_os = "macos")]
        visual_pages,
    })
}

#[cfg(target_os = "macos")]
fn recognize_visual_pages(
    doc: &PdfDocument,
    requested: &[usize],
    page_contents: &[PageContent],
) -> Result<Vec<crate::ocr::TranscriptPage>, ConvertError> {
    use pdf_oxide::rendering::{PageRenderer, RenderOptions};

    let mut renderer = PageRenderer::new(RenderOptions::with_dpi(450));
    let mut transcripts = Vec::new();
    for &page_number in requested {
        let page = &page_contents[page_number - 1];
        // Empty and nearly empty native pages may be raster-only. Keep them
        // outside this OCR path so the born-digital track cannot imply OCR
        // coverage for the separate raster benchmark.
        if page.markdown().chars().count() < 100 {
            continue;
        }
        let image = renderer
            .render_page(doc, page_number - 1)
            .map_err(|error| ConvertError::Ocr { page: page_number, reason: error.to_string() })?;
        let full_page_lines = crate::ocr::recognize_png(&image.data)
            .map_err(|reason| ConvertError::Ocr { page: page_number, reason })?;
        let has_status_card = crate::ocr::has_status_card_signature(&full_page_lines);
        let recognized = if has_status_card {
            let card_region = crate::ocr::recognize_png_in_region(&image.data, STATUS_CARD_REGION)
                .map_err(|reason| ConvertError::Ocr { page: page_number, reason })?;
            crate::ocr::merge_region_recognitions(
                full_page_lines,
                card_region,
                STATUS_CARD_REGION,
            )
        } else {
            full_page_lines
        };
        let native_regions = page
            .debug_blocks
            .iter()
            .map(|block| block.region)
            .collect::<Vec<_>>();
        let mut visual_lines = crate::ocr::keep_visual_lines(recognized, &native_regions);
        let figure_candidates = visual_lines
            .iter()
            .filter(|line| !has_status_card || line.region[0] < 0.64)
            .cloned()
            .collect::<Vec<_>>();
        if let Some(region) = crate::ocr::figure_region(&figure_candidates) {
            let figure_crop = crate::ocr::recognize_png_in_figure_region(&image.data, region)
                .map_err(|reason| ConvertError::Ocr { page: page_number, reason })?;
            let merged = crate::ocr::merge_region_recognitions(visual_lines, figure_crop, region);
            let rotated_crop = crate::ocr::recognize_png_in_figure_region_rotated(&image.data, region)
                .map_err(|reason| ConvertError::Ocr { page: page_number, reason })?;
            let merged = crate::ocr::merge_rotated_year_ticks(merged, rotated_crop);
            visual_lines = crate::ocr::keep_visual_lines(merged, &native_regions);
        }
        if !visual_lines.is_empty() {
            transcripts.push(crate::ocr::transcript_page(page_number, visual_lines));
        }
    }
    Ok(transcripts)
}
