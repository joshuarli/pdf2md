use std::fs;
use std::io::{self, Write};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;

use crate::page::PageDebug;

/// Write UTF-8 through a unique hidden sibling and an atomic rename, so
/// readers never see partially written Markdown and independent writers
/// never share a staging file. A sibling rename never crosses filesystems.
pub fn write_atomically(markdown: &str, path: &Path) -> io::Result<()> {
    let name = path.file_name().ok_or_else(|| io::Error::other("output path has no file name"))?;
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_nanos());
    let temporary = path.with_file_name(format!(
        ".{}.{}-{nanos}.tmp",
        name.to_string_lossy(),
        std::process::id()
    ));
    let result = (|| {
        let mut file = fs::File::create_new(&temporary)?;
        file.write_all(markdown.as_bytes())?;
        file.sync_all()?;
        fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

/// Write per-page JSON diagnostics and a small document manifest. Like the
/// Markdown output, each file appears atomically so an interrupted run never
/// leaves a partially encoded page record.
pub fn write_debug_pages(directory: &Path, pages: &[PageDebug]) -> io::Result<()> {
    #[derive(Serialize)]
    struct Manifest {
        pages: String,
        repaired: String,
    }

    fs::create_dir_all(directory)?;
    for page in pages {
        let json = serde_json::to_string_pretty(page).map_err(io::Error::other)?;
        let path = directory.join(format!("page-{:04}.json", page.page_number));
        write_atomically(&json, &path)?;
    }
    let manifest = Manifest { pages: pages.len().to_string(), repaired: "0".to_string() };
    let json = serde_json::to_string_pretty(&manifest).map_err(io::Error::other)?;
    write_atomically(&json, &directory.join("document.json"))
}
