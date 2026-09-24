//! Order-sensitive fidelity scoring (plan.md section 10).
//!
//! `match = 1 - edit_cost(candidate, gold) / token_count(gold)` over
//! normalized tokens. Insertions are reported separately so
//! recall-by-hallucination cannot hide behind a good match rate. This is a
//! behaviour-preserving port of the Swift scorer so historical benchmark
//! numbers in `Benchmarks/AI2027/README.md` stay comparable.

use std::collections::HashMap;
use std::sync::LazyLock;

use regex::Regex;
use unicode_normalization::UnicodeNormalization;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ScoreReport {
    pub gold_tokens: usize,
    pub candidate_tokens: usize,
    pub matching_tokens: usize,
    pub deletions: usize,
    pub insertions: usize,
    pub replacements: usize,
    pub text_match: f64,
    pub novel_text: f64,
}

impl ScoreReport {
    fn new(
        gold_tokens: usize,
        candidate_tokens: usize,
        matching_tokens: usize,
        deletions: usize,
        insertions: usize,
        replacements: usize,
    ) -> Self {
        let edit_cost = (deletions + insertions + replacements) as f64;
        let text_match = if gold_tokens > 0 {
            (1.0 - edit_cost / gold_tokens as f64).max(0.0)
        } else if candidate_tokens == 0 {
            1.0
        } else {
            0.0
        };
        let novel_text = if candidate_tokens > 0 {
            (insertions + replacements) as f64 / candidate_tokens as f64
        } else {
            0.0
        };
        Self {
            gold_tokens,
            candidate_tokens,
            matching_tokens,
            deletions,
            insertions,
            replacements,
            text_match,
            novel_text,
        }
    }

    pub fn format(&self, title: &str) -> String {
        let percent = |v: f64| format!("{}", (v * 10000.0).round() / 100.0);
        format!(
            "{title}\n  text match:       {}%\n  novel text:       {}%\n  gold tokens:      {}\n  candidate tokens: {}\n  matching:         {}\n  deletions:        {}\n  insertions:       {}\n  replacements:    {}",
            percent(self.text_match),
            percent(self.novel_text),
            self.gold_tokens,
            self.candidate_tokens,
            self.matching_tokens,
            self.deletions,
            self.insertions,
            self.replacements,
        )
    }
}

pub fn score_markdown(candidate: &str, golden: &str) -> ScoreReport {
    score_tokens(
        &tokenize(&normalize_for_scoring(golden)),
        &tokenize(&normalize_for_scoring(candidate)),
    )
}

pub fn score_tokens(gold: &[String], candidate: &[String]) -> ScoreReport {
    let matches = align_tokens(gold, candidate);
    let (mut deletions, mut insertions, mut replacements) = (0, 0, 0);
    let (mut gi, mut ci) = (0, 0);
    let mut tally = |del: usize, ins: usize| {
        // A hunk deleting and inserting together is a substitution, not an
        // independent omission plus fabrication.
        let paired = del.min(ins);
        replacements += paired;
        deletions += del - paired;
        insertions += ins - paired;
    };
    for &(mg, mc) in &matches {
        tally(mg - gi, mc - ci);
        gi = mg + 1;
        ci = mc + 1;
    }
    tally(gold.len() - gi, candidate.len() - ci);
    ScoreReport::new(gold.len(), candidate.len(), matches.len(), deletions, insertions, replacements)
}

// MARK: normalization

static FOOTNOTE_REF: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\[\^([^\]]+)\]").unwrap());
static LINK: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\[([^\]]*)\]\([^)]*\)").unwrap());
static HEADING: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?m)^\s{0,3}#{1,6}\s+").unwrap());
static BULLET: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?m)^\s{0,3}[-*+]\s+").unwrap());
static ORDERED: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?m)^\s{0,3}\d+[.)]\s+").unwrap());
static QUOTE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?m)^\s{0,3}>\s?").unwrap());
static INLINE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(\*\*|__|\*|_|`{1,3}|~~|<br\s*/?>)").unwrap());

const LIGATURES: &[(&str, &str)] = &[
    ("ﬁ", "fi"), ("ﬂ", "fl"), ("ﬀ", "ff"),
    ("ﬃ", "ffi"), ("ﬄ", "ffl"), ("ﬅ", "st"), ("ﬆ", "st"),
    ("æ", "ae"), ("œ", "oe"), ("Æ", "AE"), ("Œ", "OE"),
    ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{2018}", "'"), ("\u{2019}", "'"),
    ("–", "-"), ("—", "-"), ("…", "..."),
];

/// Candidate and gold go through the identical pipeline before tokenization:
/// Unicode/ligature/soft-hyphen handling, Markdown syntax reduced to visible
/// text, whitespace collapse. Must never erase meaningful words, numbers, or
/// punctuation to flatter the score.
pub fn normalize_for_scoring(text: &str) -> String {
    let mut result: String = text.nfc().filter(|&c| c != '\u{00AD}').collect();
    for (from, to) in LIGATURES {
        result = result.replace(from, to);
    }
    result = result.chars().map(fold_superscript).collect();
    result = reduce_markdown(&result);
    result.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn fold_superscript(c: char) -> char {
    match c {
        '⁰' => '0',
        '¹' => '1',
        '²' => '2',
        '³' => '3',
        '⁴' => '4',
        '⁵' => '5',
        '⁶' => '6',
        '⁷' => '7',
        '⁸' => '8',
        '⁹' => '9',
        _ => c,
    }
}

fn reduce_markdown(text: &str) -> String {
    // Footnote markers first so link reduction cannot eat them.
    let r = FOOTNOTE_REF.replace_all(text, " ");
    let r = LINK.replace_all(&r, "$1");
    let r = HEADING.replace_all(&r, "");
    let r = BULLET.replace_all(&r, "");
    let r = ORDERED.replace_all(&r, "");
    let r = QUOTE.replace_all(&r, "");
    let r = r.replace('|', " ");
    INLINE.replace_all(&r, " ").into_owned()
}

/// Words, numbers, and meaningful punctuation. Words fold to lowercase
/// (fidelity is about content, not caps); numbers and punctuation stay exact
/// because `12,500` vs `12500` is a real error.
pub fn tokenize(normalized: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    for c in normalized.chars() {
        if c.is_alphanumeric() {
            current.push(c);
        } else {
            if !current.is_empty() {
                tokens.push(current.to_lowercase());
                current.clear();
            }
            if !c.is_whitespace() {
                tokens.push(c.to_string());
            }
        }
    }
    if !current.is_empty() {
        tokens.push(current.to_lowercase());
    }
    tokens
}

// MARK: alignment

const MAX_WINDOW_PRODUCT: usize = 4_000_000;
const MAX_MYERS_D: usize = 5_000;

/// Patience alignment: tokens unique to both windows anchor the comparison
/// and Myers runs within the pieces between anchors. Moved blocks (gold
/// footnotes at page end vs candidate footnotes inline) become honestly
/// counted change hunks instead of pushing the global edit distance past
/// measurability. Windows with no unique anchor fall back to capped Myers.
pub fn align_tokens(gold: &[String], candidate: &[String]) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    patience(gold, 0, gold.len(), candidate, 0, candidate.len(), &mut out);
    out
}

fn patience(
    gold: &[String],
    g0: usize,
    g1: usize,
    cand: &[String],
    c0: usize,
    c1: usize,
    out: &mut Vec<(usize, usize)>,
) {
    if g0 >= g1 || c0 >= c1 {
        return;
    }
    let myers_window = |out: &mut Vec<(usize, usize)>| {
        out.extend(myers_matches(&gold[g0..g1], &cand[c0..c1]).into_iter().map(|(g, c)| (g + g0, c + c0)));
    };
    if (g1 - g0) * (c1 - c0) <= MAX_WINDOW_PRODUCT {
        return myers_window(out);
    }
    // Unique-in-window anchor nearest the middle keeps recursion balanced.
    let mut gold_counts: HashMap<&str, usize> = HashMap::new();
    for t in &gold[g0..g1] {
        *gold_counts.entry(t).or_default() += 1;
    }
    let mut cand_counts: HashMap<&str, (usize, usize)> = HashMap::new();
    for (i, t) in cand.iter().enumerate().take(c1).skip(c0) {
        let e = cand_counts.entry(t).or_default();
        e.0 += 1;
        e.1 = i;
    }
    let mid = (g0 + g1) / 2;
    let mut anchor = None;
    'search: for radius in 0.. {
        let lo = mid.checked_sub(radius).filter(|&i| i >= g0);
        let hi = Some(mid + radius).filter(|&i| i < g1);
        if lo.is_none() && hi.is_none() {
            break;
        }
        for i in [lo, hi].into_iter().flatten() {
            let token = gold[i].as_str();
            if gold_counts[token] == 1
                && let Some(&(1, c)) = cand_counts.get(token)
            {
                anchor = Some((i, c));
                break 'search;
            }
        }
    }
    let Some((ga, ca)) = anchor else {
        // No anchor: capped Myers decides (usually aborts to all-change).
        return myers_window(out);
    };
    patience(gold, g0, ga, cand, c0, ca, out);
    out.push((ga, ca));
    patience(gold, ga + 1, g1, cand, ca + 1, c1, out);
}

/// Myers greedy LCS over one window. A forward-only pass finds the edit
/// distance with O(D) memory, then a second pass records the trace for
/// backtracking. Inputs whose distance exceeds the cap abort to no matches
/// instead of exploding time/memory: catastrophic drafts fail loudly with an
/// honest 0% rather than hanging the runner.
fn myers_matches(gold: &[String], cand: &[String]) -> Vec<(usize, usize)> {
    let (n, m) = (gold.len() as isize, cand.len() as isize);
    if n == 0 || m == 0 || (n - m).unsigned_abs() > MAX_MYERS_D {
        return Vec::new();
    }
    let cap = MAX_MYERS_D.min((n + m) as usize) as isize;
    let offset = cap;
    let width = (2 * cap + 1) as usize;

    // One Myers sweep for distance `d`; returns whether the end was reached.
    let step = |v: &mut [isize], d: isize| -> bool {
        let mut k = -d;
        while k <= d {
            let idx = (offset + k) as usize;
            let mut x = if k == -d || (k != d && v[idx - 1] < v[idx + 1]) { v[idx + 1] } else { v[idx - 1] + 1 };
            let mut y = x - k;
            while x < n && y < m && gold[x as usize] == cand[y as usize] {
                x += 1;
                y += 1;
            }
            v[idx] = x;
            if x >= n && y >= m {
                return true;
            }
            k += 2;
        }
        false
    };

    let mut v = vec![-1isize; width];
    v[(offset + 1) as usize] = 0;
    let Some(distance) = (0..=cap).find(|&d| step(&mut v, d)) else {
        return Vec::new();
    };

    let mut v = vec![-1isize; width];
    v[(offset + 1) as usize] = 0;
    let mut trace = Vec::with_capacity(distance as usize + 1);
    for d in 0..=distance {
        trace.push(v.clone());
        step(&mut v, d);
    }

    let mut matches = Vec::new();
    let (mut x, mut y) = (n, m);
    for d in (1..=distance).rev() {
        let prev = &trace[d as usize];
        let k = x - y;
        let idx = (offset + k) as usize;
        let prev_k = if k == -d || (k != d && prev[idx - 1] < prev[idx + 1]) { k + 1 } else { k - 1 };
        let prev_x = prev[(offset + prev_k) as usize];
        let prev_y = prev_x - prev_k;
        while x > prev_x && y > prev_y {
            x -= 1;
            y -= 1;
            matches.push((x as usize, y as usize));
        }
        x = prev_x;
        y = prev_y;
    }
    while x > 0 && y > 0 {
        x -= 1;
        y -= 1;
        matches.push((x as usize, y as usize));
    }
    matches.reverse();
    matches
}

#[cfg(test)]
mod tests {
    use super::*;

    fn toks(s: &str) -> Vec<String> {
        tokenize(&normalize_for_scoring(s))
    }

    #[test]
    fn markdown_syntax_does_not_count_as_content() {
        let r = score_markdown("# Title\n\n- **one** [two](http://x) | three[^1]", "Title one two three");
        assert_eq!(r.text_match, 1.0);
        assert_eq!(r.novel_text, 0.0);
    }

    #[test]
    fn numbers_and_punctuation_stay_exact() {
        assert_eq!(toks("12,500 Words"), ["12", ",", "500", "words"]);
        assert_eq!(toks("ﬁne—x²"), ["fine", "-", "x2"]);
    }

    #[test]
    fn substitution_is_one_replacement_not_two_edits() {
        let r = score_tokens(&toks("a b c d"), &toks("a x c d"));
        assert_eq!((r.matching_tokens, r.replacements, r.deletions, r.insertions), (3, 1, 0, 0));
        assert_eq!(r.text_match, 0.75);
        assert_eq!(r.novel_text, 0.25);
    }

    #[test]
    fn insertions_and_deletions_are_separated() {
        let r = score_tokens(&toks("a b c"), &toks("a b c d e"));
        assert_eq!((r.insertions, r.deletions), (2, 0));
        let r = score_tokens(&toks("a b c d e"), &toks("b c"));
        assert_eq!((r.insertions, r.deletions), (0, 3));
    }

    #[test]
    fn empty_inputs() {
        assert_eq!(score_tokens(&[], &[]).text_match, 1.0);
        assert_eq!(score_tokens(&[], &toks("x")).text_match, 0.0);
    }
}
