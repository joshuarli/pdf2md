//! Thin CLI entry. stdout carries Markdown only; diagnostics go to stderr
//! as one line, never a backtrace. Exit codes: 0 ok, 1 conversion/IO
//! failure, 2 usage error.

use std::io::Write;
use std::path::Path;
use std::process::ExitCode;

use pdfmd::cli::{CliAction, USAGE, VERSION, parse_arguments};
use pdfmd::output::write_atomically;
use pdfmd::pipeline::convert;

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
    let conversion = match convert(Path::new(&options.input), options.pages.as_deref()) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let markdown = conversion.markdown();
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
