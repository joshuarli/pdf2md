//! Thin CLI entry. stdout carries Markdown only; diagnostics go to stderr
//! as one line, never a backtrace. Exit codes: 0 ok, 1 conversion/IO
//! failure, 2 usage error.

use std::io::Write;
use std::path::Path;
use std::process::ExitCode;

use pdfmd::cli::{CliAction, USAGE, VERSION, parse_arguments};
use pdfmd::output::{write_atomically, write_debug_pages};
use pdfmd::pipeline::convert_with_debug;

fn main() -> ExitCode {
    let options = match parse_arguments(std::env::args().skip(1)) {
        Ok(CliAction::Help) => {
            println!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        Ok(CliAction::Version) => {
            println!("pdfmd {VERSION}");
            return ExitCode::SUCCESS;
        }
        Ok(CliAction::Run(options)) => options,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::from(2);
        }
    };
    let conversion = match convert_with_debug(
        Path::new(&options.input),
        options.pages.as_deref(),
        options.debug_dir.is_some(),
    ) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let markdown = conversion.markdown();
    if let Some(directory) = &options.debug_dir {
        let pages = conversion.debug_pages.as_deref().unwrap_or_default();
        if let Err(error) = write_debug_pages(Path::new(directory), pages) {
            eprintln!("pdfmd: cannot write debug output {directory}: {error}");
            return ExitCode::FAILURE;
        }
    }
    let written = match &options.output {
        Some(out) => write_atomically(&markdown, Path::new(out))
            .map_err(|e| format!("pdfmd: cannot write {out}: {e}")),
        None => std::io::stdout().lock().write_all(markdown.as_bytes()).map_err(|e| format!("pdfmd: {e}")),
    };
    if let Err(message) = written {
        eprintln!("{message}");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}
