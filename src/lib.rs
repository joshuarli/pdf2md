//! pdfmd: PDF → faithful Markdown on top of pdf_oxide.

pub mod bench;
pub mod cli;
pub mod output;
pub mod page;
pub mod pipeline;
pub mod score;
#[cfg(target_os = "macos")]
pub mod ocr;
