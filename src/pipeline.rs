//! Conversion pipeline: pdf_oxide extraction → per-page Markdown.

use std::fmt;
use std::path::Path;

use pdf_oxide::PdfDocument;

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
}

impl Conversion {
    pub fn markdown(&self) -> String {
        let joined = self.pages.iter().map(|p| p.markdown.trim()).filter(|m| !m.is_empty()).collect::<Vec<_>>();
        joined.join("\n\n") + "\n"
    }
}

/// Convert `pages` (1-based; `None` = whole document) of the PDF at `path`.
pub fn convert(path: &Path, pages: Option<&[usize]>) -> Result<Conversion, ConvertError> {
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
    let mut drafts = Vec::with_capacity(requested.len());
    for page_number in requested {
        let text = doc
            .extract_text(page_number - 1)
            .map_err(|e| ConvertError::Extract { page: page_number, reason: e.to_string() })?;
        drafts.push(PageDraft { page_number, markdown: text });
    }
    Ok(Conversion { pages: drafts })
}
