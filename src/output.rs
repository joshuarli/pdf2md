use std::fs;
use std::io::{self, Write};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

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
