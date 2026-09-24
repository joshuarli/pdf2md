//! Minimal CLI parsing. The interface is small enough to parse directly; an
//! argument-parser crate is an explicit non-goal (plan.md section 14).

use std::collections::BTreeSet;
use std::fmt;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

pub const USAGE: &str = "\
pdfmd — extract a PDF into clean Markdown, fully on-device

Usage:

  pdfmd INPUT.pdf
  pdfmd INPUT.pdf -o OUTPUT.md
  pdfmd INPUT.pdf --pages 1,3-7,12
  pdfmd INPUT.pdf --debug-dir DIR

  pdfmd --help
  pdfmd --version

Defaults: the whole document; Markdown to stdout when -o is omitted
(diagnostics go to stderr); 1-based page numbers.";

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct CliOptions {
    pub input: String,
    pub output: Option<String>,
    /// Sorted, deduplicated, 1-based. `None` means the whole document.
    pub pages: Option<Vec<usize>>,
    pub debug_dir: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CliAction {
    Run(CliOptions),
    Help,
    Version,
}

/// Usage errors: exit code 2, one line (plus a hint) on stderr.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CliError(pub String);

impl fmt::Display for CliError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for CliError {}

fn err<T>(message: impl Into<String>) -> Result<T, CliError> {
    Err(CliError(message.into()))
}

pub fn parse_arguments<I: IntoIterator<Item = String>>(args: I) -> Result<CliAction, CliError> {
    let mut input = None;
    let mut output = None;
    let mut pages_spec = None;
    let mut debug_dir = None;

    let mut args = args.into_iter();
    while let Some(arg) = args.next() {
        let slot = match arg.as_str() {
            "-h" | "--help" | "help" => return Ok(CliAction::Help),
            "-V" | "--version" => return Ok(CliAction::Version),
            "-o" | "--output" => &mut output,
            "--pages" => &mut pages_spec,
            "--debug-dir" => &mut debug_dir,
            flag if flag.starts_with('-') => {
                return err(format!("pdfmd: unknown flag: {flag}\nTry `pdfmd --help`."));
            }
            _ => {
                if input.is_some() {
                    return err(format!("pdfmd: unexpected argument: {arg}"));
                }
                input = Some(arg);
                continue;
            }
        };
        let Some(value) = args.next() else {
            return err(format!("pdfmd: {arg} requires a value"));
        };
        if slot.is_some() {
            return err(format!("pdfmd: {arg} given twice"));
        }
        *slot = Some(value);
    }

    let Some(input) = input else {
        return err("pdfmd: missing input PDF\nTry `pdfmd --help`.");
    };
    let pages = pages_spec.as_deref().map(parse_page_spec).transpose()?;
    Ok(CliAction::Run(CliOptions { input, output, pages, debug_dir }))
}

/// Parse `1,3-7,12` into sorted, deduplicated 1-based page numbers. Upper
/// bounds are validated later against the actual document; here only shape
/// is checked (positive integers, lo <= hi).
pub fn parse_page_spec(spec: &str) -> Result<Vec<usize>, CliError> {
    let positive = |s: &str| s.trim().parse::<usize>().ok().filter(|&n| n >= 1);
    let mut result = BTreeSet::new();
    for raw in spec.split(',') {
        let token = raw.trim();
        if token.is_empty() {
            return err(if spec.trim().is_empty() {
                "pdfmd: empty --pages specification"
            } else {
                "pdfmd: empty entry in --pages specification"
            });
        }
        if let Some((lo, hi)) = token.split_once('-') {
            let (Some(lo), Some(hi)) = (positive(lo), positive(hi)) else {
                return err(format!("pdfmd: invalid page range: {token}"));
            };
            if lo > hi {
                return err(format!("pdfmd: reversed page range: {token}"));
            }
            result.extend(lo..=hi);
        } else {
            let Some(page) = positive(token) else {
                return err(format!("pdfmd: invalid page number: {token}"));
            };
            result.insert(page);
        }
    }
    Ok(result.into_iter().collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(args: &[&str]) -> Result<CliAction, CliError> {
        parse_arguments(args.iter().map(|s| s.to_string()))
    }

    #[test]
    fn page_spec_sorts_and_dedups() {
        assert_eq!(parse_page_spec("12, 3-5,1,4").unwrap(), [1, 3, 4, 5, 12]);
    }

    #[test]
    fn page_spec_rejects_bad_shapes() {
        for bad in ["", "0", "5-3", "a", "1,,2", "2-", "-1"] {
            assert!(parse_page_spec(bad).is_err(), "{bad:?} should fail");
        }
    }

    #[test]
    fn run_options() {
        let action = parse(&["in.pdf", "-o", "out.md", "--pages", "2-3", "--debug-dir", "d"]).unwrap();
        assert_eq!(
            action,
            CliAction::Run(CliOptions {
                input: "in.pdf".into(),
                output: Some("out.md".into()),
                pages: Some(vec![2, 3]),
                debug_dir: Some("d".into()),
            })
        );
    }

    #[test]
    fn help_and_version_win() {
        assert_eq!(parse(&["x.pdf", "--help"]).unwrap(), CliAction::Help);
        assert_eq!(parse(&["-V"]).unwrap(), CliAction::Version);
    }

    #[test]
    fn usage_errors() {
        assert!(parse(&[]).unwrap_err().0.contains("missing input"));
        assert!(parse(&["a.pdf", "b.pdf"]).unwrap_err().0.contains("unexpected argument"));
        assert!(parse(&["a.pdf", "-o"]).unwrap_err().0.contains("requires a value"));
        assert!(parse(&["a.pdf", "-o", "x", "-o", "y"]).unwrap_err().0.contains("given twice"));
        assert!(parse(&["a.pdf", "--ocr"]).unwrap_err().0.contains("unknown flag"));
    }
}
