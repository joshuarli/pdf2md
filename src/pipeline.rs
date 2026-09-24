//! Conversion pipeline: pdf_oxide extraction → per-page Markdown.

use std::fmt;
use std::path::Path;

use pdf_oxide::PdfDocument;

use crate::page::{FontProfile, PageContent, PageDebug, append_line, assemble_page, strip_document_furniture};

#[derive(Debug)]
pub enum ConvertError {
    Open { path: String, reason: String },
    PageOutOfRange { page: usize, page_count: usize },
    Extract { page: usize, reason: String },
}

impl fmt::Display for ConvertError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Open { path, reason } => write!(f, "pdfmd: cannot open {path}: {reason}"),
            Self::PageOutOfRange { page, page_count } => {
                write!(f, "pdfmd: page {page} is out of range (document has {page_count} pages)")
            }
            Self::Extract { page, reason } => write!(f, "pdfmd: page {page}: {reason}"),
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
}

impl Conversion {
    pub fn markdown(&self) -> String {
        let joined = self.pages.iter().map(|p| p.markdown.trim()).filter(|m| !m.is_empty()).collect::<Vec<_>>();
        joined.join("\n\n") + "\n"
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

    let mut drafts = Vec::with_capacity(requested.len());
    let mut debug_pages = collect_debug.then(|| Vec::with_capacity(requested.len()));
    for page_number in requested {
        let markdown = page_contents[page_number - 1].markdown();
        if let Some(debug) = &mut debug_pages {
            debug.push(page_contents[page_number - 1].debug_page(page_number, markdown.clone()));
        }
        drafts.push(PageDraft { page_number, markdown });
    }
    Ok(Conversion { pages: drafts, debug_pages })
}
