//! Benchmark manifest, source pinning, and per-page scoring (plan.md
//! sections 7, 10, 38). The source PDF and golden Markdown stay
//! local/untracked; the repository carries only the manifest, the scoring
//! code, and methodology notes.

use std::fs::File;
use std::io::{self, Read};
use std::path::Path;

use serde::Deserialize;
use sha2::{Digest, Sha256};

use crate::score::{ScoreReport, align_tokens, score_tokens};

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BenchmarkManifest {
    pub source_filename: String,
    #[serde(rename = "sourceURL")]
    pub source_url: String,
    pub sha256: String,
    pub byte_size: u64,
    pub page_count: usize,
    pub golden_filename: String,
    pub raster_filename: String,
    pub born_digital_text_match: f64,
    pub raster_text_match: f64,
    pub raster_novel_text: f64,
    pub page_floor: f64,
}

pub fn sha256_hex(path: &Path) -> io::Result<String> {
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 1 << 20];
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        hasher.update(&buffer[..n]);
    }
    Ok(hasher.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

/// Refuse to benchmark a changed upstream document: scores are only
/// comparable against the exact bytes the golden file was curated from.
pub fn validate_source(path: &Path, manifest: &BenchmarkManifest) -> Result<(), String> {
    let actual = sha256_hex(path).map_err(|e| format!("pdfmd-bench: cannot read {}: {e}", path.display()))?;
    if actual != manifest.sha256.to_lowercase() {
        return Err(format!(
            "pdfmd-bench: {} SHA-256 mismatch (expected {}, got {actual}); refusing to benchmark a changed upstream document",
            manifest.source_filename, manifest.sha256
        ));
    }
    Ok(())
}

#[derive(Debug, Clone)]
pub struct PageScore {
    pub page_number: usize,
    pub report: ScoreReport,
}

/// Approximate per-page fidelity for the catastrophic-page guardrail
/// (plan.md section 11: "no substantive page < 85%").
///
/// `golden.md` is one continuous transcription with no page markers
/// (footnotes relocate, paragraphs join across page breaks), so each gold
/// page boundary is found by linearly interpolating the whole-document
/// alignment at the candidate page's token cut point. Matches are monotonic
/// in both sequences, so boundaries are monotonic too and every page gets a
/// genuine, non-overlapping gold slice.
pub fn score_pages(gold: &[String], candidate_pages: &[(usize, Vec<String>)]) -> Vec<PageScore> {
    let candidate: Vec<String> = candidate_pages.iter().flat_map(|(_, t)| t.iter().cloned()).collect();
    let matches = align_tokens(gold, &candidate);

    let mut page_starts = vec![0];
    for (_, tokens) in candidate_pages {
        page_starts.push(page_starts.last().unwrap() + tokens.len());
    }

    let mut boundaries = vec![0];
    let mut lo = 0;
    for &c in &page_starts[1..page_starts.len() - 1] {
        while lo < matches.len() && matches[lo].1 < c {
            lo += 1;
        }
        let prev = lo.checked_sub(1).map(|i| matches[i]);
        let next = matches.get(lo).copied();
        let g = match (prev, next) {
            (None, None) => 0,
            (None, Some(n)) => {
                if c <= n.1 {
                    0
                } else {
                    n.0
                }
            }
            (Some(p), None) => p.0 + 1,
            (Some(p), Some(n)) if n.1 <= p.1 => p.0 + 1,
            (Some(p), Some(n)) => {
                let fraction = (c - p.1) as f64 / (n.1 - p.1) as f64;
                let g = p.0 as f64 + ((n.0 - p.0) as f64 * fraction).round();
                (g as usize).clamp(p.0, n.0)
            }
        };
        boundaries.push(g.max(*boundaries.last().unwrap()));
    }
    boundaries.push(gold.len());

    candidate_pages
        .iter()
        .enumerate()
        .map(|(i, (page_number, tokens))| PageScore {
            page_number: *page_number,
            report: score_tokens(&gold[boundaries[i]..boundaries[i + 1]], tokens),
        })
        .collect()
}

/// The worst page with at least `minimum_aligned` matches, so a near-empty
/// page (a cover, a chart-only page) cannot claim the slot on a handful of
/// tokens.
pub fn worst_substantive_page(pages: &[PageScore], minimum_aligned: usize) -> Option<&PageScore> {
    pages
        .iter()
        .filter(|p| p.report.matching_tokens >= minimum_aligned)
        .min_by(|a, b| a.report.text_match.total_cmp(&b.report.text_match))
}

/// Unmatched hunks between gold and candidate, for heuristic work: each
/// entry is (gold-only tokens, candidate-only tokens) with the matched
/// context immediately before it.
pub fn diff_hunks(gold: &[String], candidate: &[String]) -> Vec<(String, String, String)> {
    let matches = align_tokens(gold, candidate);
    let mut hunks = Vec::new();
    let (mut gi, mut ci) = (0, 0);
    let mut emit = |gi: usize, ci: usize, g_end: usize, c_end: usize| {
        if gi < g_end || ci < c_end {
            let context = gold[gi.saturating_sub(6)..gi].join(" ");
            hunks.push((context, gold[gi..g_end].join(" "), candidate[ci..c_end].join(" ")));
        }
    };
    for &(g, c) in &matches {
        emit(gi, ci, g, c);
        gi = g + 1;
        ci = c + 1;
    }
    emit(gi, ci, gold.len(), candidate.len());
    hunks
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::score::{normalize_for_scoring, tokenize};

    fn toks(s: &str) -> Vec<String> {
        tokenize(&normalize_for_scoring(s))
    }

    #[test]
    fn page_scores_split_gold_at_candidate_page_boundaries() {
        let gold = toks("alpha beta gamma delta epsilon zeta");
        let pages = vec![(1, toks("alpha beta gamma")), (2, toks("delta epsilon junk"))];
        let scores = score_pages(&gold, &pages);
        assert_eq!(scores[0].report.text_match, 1.0);
        assert_eq!(scores[1].report.gold_tokens, 3);
        assert_eq!(scores[1].report.replacements, 1);
    }

    #[test]
    fn hunks_report_both_sides() {
        let hunks = diff_hunks(&toks("a b c d"), &toks("a x c"));
        assert_eq!(hunks.len(), 2);
        assert_eq!((hunks[0].1.as_str(), hunks[0].2.as_str()), ("b", "x"));
        assert_eq!((hunks[1].1.as_str(), hunks[1].2.as_str()), ("d", ""));
    }
}
