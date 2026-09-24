//! Benchmark runner (plan.md section 38). A separate executable so the
//! normal `pdfmd --help` stays minimal.
//!
//! ```text
//! pdfmd-bench ai2027 [--dir Benchmarks/AI2027]
//! pdfmd-bench score --candidate CAND --golden GOLD
//! pdfmd-bench diff  --candidate CAND --golden GOLD
//! ```

use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Instant;

use pdfmd::bench::{BenchmarkManifest, diff_hunks, score_pages, validate_source, worst_substantive_page};
use pdfmd::output::write_atomically;
use pdfmd::pipeline::convert;
use pdfmd::score::{normalize_for_scoring, score_markdown, tokenize};

const USAGE: &str = "\
usage: pdfmd-bench ai2027 [--dir DIR]
       pdfmd-bench score --candidate CAND --golden GOLD
       pdfmd-bench diff --candidate CAND --golden GOLD";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let flag = |name: &str| args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned();
    let result = match args.first().map(String::as_str) {
        Some("ai2027") => run_ai2027(Path::new(&flag("--dir").unwrap_or_else(|| "Benchmarks/AI2027".into()))),
        Some(command @ ("score" | "diff")) => match (flag("--candidate"), flag("--golden")) {
            (Some(candidate), Some(golden)) => compare(command, &candidate, &golden),
            _ => Err(USAGE.into()),
        },
        _ => Err(USAGE.into()),
    };
    match result {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::FAILURE,
        Err(message) => {
            eprintln!("{message}");
            ExitCode::from(2)
        }
    }
}

fn read(path: &Path) -> Result<String, String> {
    fs::read_to_string(path).map_err(|e| format!("pdfmd-bench: cannot read {}: {e}", path.display()))
}

fn compare(command: &str, candidate: &str, golden: &str) -> Result<bool, String> {
    let (candidate, golden) = (read(Path::new(candidate))?, read(Path::new(golden))?);
    if command == "score" {
        println!("{}", score_markdown(&candidate, &golden).format("score"));
        return Ok(true);
    }
    let gold = tokenize(&normalize_for_scoring(&golden));
    let cand = tokenize(&normalize_for_scoring(&candidate));
    for (context, gold_only, cand_only) in diff_hunks(&gold, &cand) {
        println!("@@ …{context}\n- {gold_only}\n+ {cand_only}");
    }
    Ok(true)
}

fn run_ai2027(directory: &Path) -> Result<bool, String> {
    let manifest: BenchmarkManifest = serde_json::from_str(&read(&directory.join("manifest.json"))?)
        .map_err(|e| format!("pdfmd-bench: bad manifest: {e}"))?;
    let pdf = directory.join(&manifest.source_filename);
    let golden_path = directory.join(&manifest.golden_filename);
    validate_source(&pdf, &manifest)?;
    let golden = read(&golden_path).map_err(|e| format!("{e} (see Benchmarks/AI2027/README.md to create it)"))?;
    let gold_tokens = tokenize(&normalize_for_scoring(&golden));

    let started = Instant::now();
    let conversion = convert(&pdf, None).map_err(|e| e.to_string())?;
    let converted_in = started.elapsed();
    let markdown = conversion.markdown();

    let artifacts: PathBuf = directory.join("results-deterministic");
    fs::create_dir_all(&artifacts).map_err(|e| e.to_string())?;
    write_atomically(&markdown, &artifacts.join("born.md")).map_err(|e| e.to_string())?;
    let drafts: Vec<&str> = conversion.pages.iter().map(|p| p.markdown.as_str()).collect();
    let drafts_json = serde_json::to_string(&drafts).map_err(|e| e.to_string())?;
    write_atomically(&drafts_json, &artifacts.join("born-pages.json")).map_err(|e| e.to_string())?;

    let report = score_markdown(&markdown, &golden);
    let pages: Vec<(usize, Vec<String>)> = conversion
        .pages
        .iter()
        .map(|p| (p.page_number, tokenize(&normalize_for_scoring(&p.markdown))))
        .collect();
    let page_scores = score_pages(&gold_tokens, &pages);

    println!("AI 2027 — born digital\n");
    println!("{}", report.format("born digital"));
    match worst_substantive_page(&page_scores, 20) {
        Some(worst) => {
            let flag = if worst.report.text_match < manifest.page_floor {
                format!(" (below {}% floor)", (manifest.page_floor * 100.0) as u32)
            } else {
                String::new()
            };
            let percent = (worst.report.text_match * 10000.0).round() / 100.0;
            println!("  worst page:      {percent}% (page {}){flag}", worst.page_number);
        }
        None => println!("  worst page:      n/a (no substantive page)"),
    }
    // Visual OCR supplements born-digital pages, but raster-only pages still
    // need a full-page OCR path before that separate track can be scored.
    println!("\nAI 2027 — raster: skipped (full-page OCR not implemented)");
    println!("conversion: {:.2}s", converted_in.as_secs_f64());

    let pass = report.text_match >= manifest.born_digital_text_match;
    println!("{}", if pass { "PASS" } else { "FAIL" });
    Ok(pass)
}
