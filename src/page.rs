//! Span-based page assembly. Font size separates the document's reading flow
//! from footnotes; geometry joins spans into lines without flattening columns.

use std::collections::{BTreeMap, BTreeSet};

use pdf_oxide::layout::TextSpan;
use serde::Serialize;

/// Document-wide font sizes used to classify body text, footnotes, and raised
/// reference markers. Sizes are quantized to tenths to absorb PDF float noise.
#[derive(Debug, Clone, Copy)]
pub struct FontProfile {
    pub body_size: f32,
    pub footnote_size: Option<f32>,
    pub title_size: Option<f32>,
}

impl FontProfile {
    pub fn infer(pages: &[Vec<TextSpan>]) -> Self {
        let mut characters_by_size: BTreeMap<i32, usize> = BTreeMap::new();
        for span in pages.iter().flatten() {
            if span.artifact_type.is_none() && span.font_size > 0.0 && !span.text.trim().is_empty() {
                *characters_by_size
                    .entry((span.font_size * 10.0).round() as i32)
                    .or_default() += span.text.chars().count();
            }
        }

        let body_tenths = characters_by_size
            .iter()
            .max_by(|(size_a, count_a), (size_b, count_b)| {
                count_a.cmp(count_b).then_with(|| size_a.cmp(size_b))
            })
            .map(|(&size, _)| size)
            .unwrap_or(110);
        let body_size = body_tenths as f32 / 10.0;
        let footnote_tenths = characters_by_size
            .iter()
            .filter(|(size, _)| {
                let size = **size as f32 / 10.0;
                size >= body_size * 0.70 && size < body_size * 0.98
            })
            .max_by(|(size_a, count_a), (size_b, count_b)| {
                count_a.cmp(count_b).then_with(|| size_a.cmp(size_b))
            })
            .map(|(&size, _)| size);
        let title_size = characters_by_size
            .keys()
            .filter(|&&size| size as f32 / 10.0 > body_size * 1.05)
            .max()
            .map(|&size| size as f32 / 10.0);

        Self {
            body_size,
            footnote_size: footnote_tenths.map(|size| size as f32 / 10.0),
            title_size,
        }
    }

    fn is_footnote(&self, size: f32) -> bool {
        self.footnote_size
            .is_some_and(|footnote| (size - footnote).abs() <= 0.16)
    }

    fn is_marker(&self, span: &TextSpan) -> bool {
        span.font_size < self.body_size * 0.70 && marker_value(&span.text).is_some()
    }
}

/// Remove tagged artifacts and text repeated in the top or bottom page bands.
/// The per-page threshold prevents one-off titles and footnotes from becoming
/// furniture while folding changing page numbers into one repeated key.
pub fn strip_document_furniture(
    pages: &mut [Vec<TextSpan>],
    media_boxes: &[(f32, f32, f32, f32)],
    profile: &FontProfile,
) {
    for page in pages.iter_mut() {
        page.retain(|span| span.artifact_type.is_none());
    }
    if pages.len() < 3 {
        return;
    }

    let threshold = 3.max(pages.len() / 3);
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    let mut candidates_by_page: Vec<Vec<(String, BTreeSet<usize>)>> = Vec::with_capacity(pages.len());
    for (page_index, spans) in pages.iter().enumerate() {
        let mut keys_on_page = BTreeSet::new();
        let mut candidates = Vec::new();
        let (_, y0, _, y1) = media_boxes[page_index];
        let height = y1 - y0;
        if height <= 0.0 {
            candidates_by_page.push(candidates);
            continue;
        }
        for line in group_lines(spans.clone(), profile.body_size) {
            let largest_font = line.spans.iter().map(|span| span.font_size).fold(0.0, f32::max);
            if largest_font > profile.body_size * 1.05 {
                continue;
            }
            let vertical_position = (line.baseline - y0) / height;
            let band = if vertical_position >= 0.88 {
                "top"
            } else if vertical_position <= 0.12 {
                "bottom"
            } else {
                continue;
            };
            let span_refs: Vec<&TextSpan> = line.spans.iter().collect();
            let text = compose_spans(&span_refs, None, profile);
            if text.is_empty() || text.chars().count() >= 200 {
                continue;
            }
            let Some(key) = furniture_key(&text, band) else {
                continue;
            };
            keys_on_page.insert(key.clone());
            candidates.push((key, line.spans.iter().map(|span| span.sequence).collect()));
        }
        for key in keys_on_page {
            *counts.entry(key).or_default() += 1;
        }
        candidates_by_page.push(candidates);
    }

    let repeated: BTreeSet<String> = counts
        .into_iter()
        .filter_map(|(key, count)| (count >= threshold).then_some(key))
        .collect();
    if repeated.is_empty() {
        return;
    }
    for (spans, candidates) in pages.iter_mut().zip(candidates_by_page) {
        let sequences: BTreeSet<usize> = candidates
            .into_iter()
            .filter(|(key, _)| repeated.contains(key))
            .flat_map(|(_, sequences)| sequences)
            .collect();
        spans.retain(|span| !sequences.contains(&span.sequence));
    }
}

fn furniture_key(text: &str, band: &str) -> Option<String> {
    let mut folded = String::new();
    let mut in_digits = false;
    for character in text.trim().to_lowercase().chars() {
        if character.is_numeric() {
            if !in_digits {
                folded.push('#');
            }
            in_digits = true;
        } else {
            in_digits = false;
            folded.push(character);
        }
    }
    let normalized = folded.split_whitespace().collect::<Vec<_>>().join(" ");
    (!normalized.is_empty()).then(|| format!("{band}:{normalized}"))
}

#[derive(Debug, Clone)]
pub struct FootnoteDefinition {
    pub marker: String,
    pub text: String,
}

#[derive(Debug, Clone)]
pub struct PageContent {
    pub paragraphs: Vec<String>,
    pub footnotes: Vec<FootnoteDefinition>,
    /// Markerless footnote lines at the start of the page can continue the
    /// previous page's final definition.
    pub footnote_continuations: Vec<String>,
    pub debug_blocks: Vec<DebugBlock>,
}

#[derive(Debug, Clone, Serialize)]
pub struct PageDebug {
    #[serde(rename = "pageNumber")]
    pub page_number: usize,
    #[serde(rename = "nativeTextQuality")]
    pub native_text_quality: String,
    #[serde(rename = "nativeCharacters")]
    pub native_characters: usize,
    pub blocks: Vec<DebugBlock>,
    #[serde(rename = "deterministicMarkdown")]
    pub deterministic_markdown: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct DebugBlock {
    pub kind: String,
    pub source: String,
    pub text: String,
    pub region: [f64; 4],
}

impl PageContent {
    pub fn markdown(&self) -> String {
        let mut sections = self.paragraphs.clone();
        sections.extend(
            self.footnotes
                .iter()
                .map(|footnote| format!("[^{}]: {}", footnote.marker, footnote.text)),
        );
        sections.join("\n\n")
    }

    pub fn debug_page(&self, page_number: usize, markdown: String) -> PageDebug {
        let native_characters = markdown.chars().count();
        PageDebug {
            page_number,
            native_text_quality: if native_characters == 0 { "empty" } else { "trustworthy" }.to_string(),
            native_characters,
            blocks: self.debug_blocks.clone(),
            deterministic_markdown: markdown,
        }
    }
}

#[derive(Debug)]
struct Line {
    spans: Vec<TextSpan>,
    sequence: usize,
    baseline: f32,
}

#[derive(Debug)]
struct FootnoteLine {
    sequence: usize,
    marker: Option<String>,
    text: String,
}

/// Assemble spans from one page into body paragraphs and page-end footnotes.
pub fn assemble_page(
    spans: Vec<TextSpan>,
    profile: FontProfile,
    media_box: (f32, f32, f32, f32),
) -> PageContent {
    let mut lines = group_lines(spans, profile.body_size);
    lines.sort_by_key(|line| line.sequence);

    let mut footnote_lines = Vec::new();
    let mut flow_lines = Vec::new();
    let mut debug_blocks = Vec::new();
    for line in lines {
        if profile.footnote_size.is_some() && line.spans.iter().any(|s| profile.is_footnote(s.font_size)) {
            let note_spans: Vec<&TextSpan> = line
                .spans
                .iter()
                .filter(|span| profile.is_footnote(span.font_size))
                .collect();
            let first_note_x = note_spans
                .iter()
                .map(|span| span.bbox.x)
                .fold(f32::INFINITY, f32::min);
            let marker_span = line
                .spans
                .iter()
                .filter(|span| profile.is_marker(span) && span.bbox.x <= first_note_x)
                .filter(|span| {
                    let marker_right = span.bbox.x + span.bbox.width;
                    first_note_x - marker_right <= profile.footnote_size.unwrap_or(profile.body_size) * 1.5
                })
                .min_by(|a, b| a.bbox.x.total_cmp(&b.bbox.x));
            let marker = marker_span.and_then(|span| marker_value(&span.text));
            let text = compose_spans(&note_spans, None, &profile);
            let debug_text = marker
                .as_ref()
                .map_or_else(|| text.clone(), |marker| format!("[^{marker}]: {text}"));
            debug_blocks.push(debug_block("footnote", debug_text, &line.spans, media_box));
            footnote_lines.push(FootnoteLine {
                sequence: line.sequence,
                marker,
                text,
            });
        } else {
            flow_lines.push(line);
        }
    }

    footnote_lines.sort_by_key(|line| line.sequence);
    let mut footnotes = Vec::new();
    let mut continuations = Vec::new();
    let mut current: Option<FootnoteDefinition> = None;
    for line in footnote_lines {
        if let Some(marker) = line.marker {
            if let Some(definition) = current.take() {
                footnotes.push(definition);
            }
            current = Some(FootnoteDefinition { marker, text: line.text });
        } else if let Some(definition) = current.as_mut() {
            append_line(&mut definition.text, &line.text);
        } else if !line.text.is_empty() {
            continuations.push(line.text);
        }
    }
    if let Some(definition) = current {
        footnotes.push(definition);
    }

    let known_markers: BTreeMap<String, ()> = footnotes
        .iter()
        .map(|definition| (definition.marker.clone(), ()))
        .collect();
    // Re-render flow lines after note markers are known so unrelated small
    // display text remains literal while matched raised markers become refs.
    let mut body_lines = Vec::new();
    for line in flow_lines {
        let flow_spans: Vec<&TextSpan> = line
            .spans
            .iter()
            .filter(|span| !profile.is_footnote(span.font_size))
            .collect();
        let text = compose_spans(&flow_spans, Some(&known_markers), &profile);
        if !text.is_empty() {
            let size = flow_spans
                .iter()
                .map(|span| span.font_size)
                .fold(profile.body_size, f32::max);
            let left = flow_spans
                .iter()
                .map(|span| span.bbox.x)
                .fold(f32::INFINITY, f32::min);
            let heading_left_limit = media_box.0 + (media_box.2 - media_box.0) * 0.22;
            let kind = flow_kind(size, left, heading_left_limit, &profile);
            debug_blocks.push(debug_block(kind, text.clone(), &line.spans, media_box));
            body_lines.push((line.sequence, line.baseline, size, left, text));
        }
    }
    let paragraphs = group_paragraphs(body_lines, &profile, media_box);

    PageContent {
        paragraphs,
        footnotes,
        footnote_continuations: continuations,
        debug_blocks,
    }
}

fn flow_kind(size: f32, left: f32, heading_left_limit: f32, profile: &FontProfile) -> &'static str {
    if profile
        .title_size
        .is_some_and(|title_size| (size - title_size).abs() <= 0.16)
    {
        "title"
    } else if size > profile.body_size * 1.05 && left <= heading_left_limit {
        "heading-2"
    } else {
        "paragraph"
    }
}

fn debug_block(
    kind: &str,
    text: String,
    spans: &[TextSpan],
    media_box: (f32, f32, f32, f32),
) -> DebugBlock {
    let (x0, y0, x1, y1) = media_box;
    let left = spans.iter().map(|span| span.bbox.x).fold(f32::INFINITY, f32::min);
    let bottom = spans.iter().map(|span| span.bbox.y).fold(f32::INFINITY, f32::min);
    let right = spans
        .iter()
        .map(|span| span.bbox.x + span.bbox.width)
        .fold(f32::NEG_INFINITY, f32::max);
    let top = spans
        .iter()
        .map(|span| span.bbox.y + span.bbox.height)
        .fold(f32::NEG_INFINITY, f32::max);
    let width = (x1 - x0).max(1.0);
    let height = (y1 - y0).max(1.0);
    let text: String = text.chars().take(2000).collect();
    DebugBlock {
        kind: kind.to_string(),
        source: "native".to_string(),
        text,
        region: [
            ((left - x0) / width) as f64,
            ((y1 - top) / height) as f64,
            ((right - left) / width) as f64,
            ((top - bottom) / height) as f64,
        ],
    }
}

// Group spans by baseline, then split distant horizontal zones so a body line
// and a margin footnote never become one paragraph when they share a y value.
fn group_lines(spans: Vec<TextSpan>, body_size: f32) -> Vec<Line> {
    let mut ordered = spans;
    ordered.sort_by(|a, b| {
        b.bbox.y
            .total_cmp(&a.bbox.y)
            .then_with(|| a.sequence.cmp(&b.sequence))
    });
    // Superscript footnote labels sit above the baseline of their first text
    // span. Half a body line pitch keeps those together while adjacent lines
    // remain separate; horizontal zones split a neighboring body line away.
    let baseline_tolerance = body_size * 0.62;
    let mut rows: Vec<Vec<TextSpan>> = Vec::new();
    for span in ordered {
        let nearest = rows
            .iter()
            .enumerate()
            .filter_map(|(index, row)| {
                let baseline = row.iter().map(|s| s.bbox.y).sum::<f32>() / row.len() as f32;
                let distance = (baseline - span.bbox.y).abs();
                (distance <= baseline_tolerance).then_some((index, distance))
            })
            .min_by(|a, b| a.1.total_cmp(&b.1))
            .map(|(index, _)| index);
        if let Some(index) = nearest {
            rows[index].push(span);
        } else {
            rows.push(vec![span]);
        }
    }

    let zone_gap = body_size * 1.5;
    let mut lines = Vec::new();
    for mut row in rows {
        row.sort_by(|a, b| a.bbox.x.total_cmp(&b.bbox.x).then_with(|| a.sequence.cmp(&b.sequence)));
        let mut component = Vec::new();
        let mut previous_right = None;
        for span in row {
            if previous_right.is_some_and(|right: f32| span.bbox.x - right > zone_gap) && !component.is_empty() {
                lines.push(make_line(std::mem::take(&mut component)));
            }
            previous_right = Some(span.bbox.x + span.bbox.width);
            component.push(span);
        }
        if !component.is_empty() {
            lines.push(make_line(component));
        }
    }
    lines
}

fn make_line(spans: Vec<TextSpan>) -> Line {
    let sequence = spans.iter().map(|span| span.sequence).min().unwrap_or(0);
    let baseline = spans.iter().map(|span| span.bbox.y).sum::<f32>() / spans.len().max(1) as f32;
    Line { spans, sequence, baseline }
}

fn compose_spans(spans: &[&TextSpan], known_markers: Option<&BTreeMap<String, ()>>, profile: &FontProfile) -> String {
    let mut ordered = spans.to_vec();
    ordered.sort_by(|a, b| a.bbox.x.total_cmp(&b.bbox.x).then_with(|| a.sequence.cmp(&b.sequence)));

    let mut text = String::new();
    let mut previous_right: Option<f32> = None;
    let mut previous_size = profile.body_size;
    for span in ordered {
        let marker = profile.is_marker(span).then(|| marker_value(&span.text)).flatten();
        let fragment = match (marker, known_markers) {
            (Some(marker), Some(known)) if known.contains_key(&marker) => format!("[^{marker}]"),
            _ => normalize_tracked_text(
                &span.text,
                span.char_spacing,
                span.font_size,
                span.bbox.width,
            ),
        };
        if let Some(right) = previous_right {
            let gap = span.bbox.x - right;
            let has_space = text.chars().last().is_some_and(char::is_whitespace)
                || fragment.chars().next().is_some_and(char::is_whitespace);
            if gap > 0.2 * previous_size.max(span.font_size) && !has_space {
                text.push(' ');
            }
        }
        text.push_str(&fragment);
        previous_right = Some(span.bbox.x + span.bbox.width);
        previous_size = span.font_size;
    }
    text.trim().to_string()
}

fn marker_value(text: &str) -> Option<String> {
    let marker = text.trim();
    if marker.is_empty() || marker.chars().count() > 3 {
        return None;
    }
    if marker.chars().all(|c| c.is_ascii_digit())
        || marker.chars().all(|c| matches!(c, '*' | '†' | '‡'))
    {
        Some(marker.to_string())
    } else {
        None
    }
}

fn normalize_tracked_text(text: &str, char_spacing: f32, font_size: f32, width: f32) -> String {
    let letters = text.chars().filter(|character| character.is_alphabetic()).count();
    let geometry_shows_tracking = letters >= 3 && width >= font_size * letters as f32 * 0.80;
    if char_spacing <= 0.0 && !geometry_shows_tracking {
        return text.to_string();
    }
    text.split("  ")
        .filter(|segment| !segment.trim().is_empty())
        .map(collapse_single_letter_runs)
        .collect::<Vec<_>>()
        .join(" ")
}

fn collapse_single_letter_runs(segment: &str) -> String {
    let words: Vec<&str> = segment.split_whitespace().collect();
    let mut result = Vec::with_capacity(words.len());
    let mut index = 0;
    while index < words.len() {
        if is_single_letter(words[index]) {
            let mut end = index + 1;
            while end < words.len() && is_single_letter(words[end]) {
                end += 1;
            }
            if end - index >= 3 {
                result.push(words[index..end].iter().map(|word| *word).collect::<String>());
            } else {
                result.extend(words[index..end].iter().map(|word| (*word).to_string()));
            }
            index = end;
        } else {
            result.push(words[index].to_string());
            index += 1;
        }
    }
    result.join(" ")
}

fn is_single_letter(word: &str) -> bool {
    let mut characters = word.chars();
    characters.next().is_some_and(char::is_alphabetic) && characters.next().is_none()
}

pub fn append_line(destination: &mut String, line: &str) {
    let line = line.trim();
    if line.is_empty() {
        return;
    }
    if destination.is_empty() {
        destination.push_str(line);
        return;
    }
    let first = line.chars().next().unwrap_or_default();
    let joins_hyphen = destination.ends_with('-') && first.is_lowercase();
    let joins_dash = destination.ends_with('—') && first.is_lowercase();
    if joins_hyphen {
        destination.pop();
        destination.push_str(line);
    } else if joins_dash {
        destination.push_str(line);
    } else {
        destination.push(' ');
        destination.push_str(line);
    }
}

fn group_paragraphs(
    mut lines: Vec<(usize, f32, f32, f32, String)>,
    profile: &FontProfile,
    media_box: (f32, f32, f32, f32),
) -> Vec<String> {
    lines.sort_by_key(|line| line.0);
    let mut paragraphs = Vec::new();
    let mut current = String::new();
    let mut previous_baseline = None;
    let mut current_size = None;
    let mut current_left = f32::INFINITY;
    let paragraph_gap = profile.body_size * 1.5;
    let heading_left_limit = media_box.0 + (media_box.2 - media_box.0) * 0.22;
    for (_, baseline, size, left, text) in lines {
        let font_change = current_size.is_some_and(|previous: f32| {
            ((previous > profile.body_size * 1.05) != (size > profile.body_size * 1.05))
                || (previous - size).abs() > profile.body_size * 0.2
        });
        let vertical_gap = previous_baseline
            .is_some_and(|previous: f32| (previous - baseline).abs() > paragraph_gap);
        if (font_change || vertical_gap) && !current.is_empty() {
            paragraphs.push(render_paragraph(
                std::mem::take(&mut current),
                current_size.unwrap_or(profile.body_size),
                current_left,
                heading_left_limit,
                profile,
            ));
            current_size = None;
            current_left = f32::INFINITY;
        }
        append_line(&mut current, &text);
        previous_baseline = Some(baseline);
        current_size = Some(current_size.map_or(size, |previous: f32| previous.max(size)));
        current_left = current_left.min(left);
    }
    if !current.is_empty() {
        paragraphs.push(render_paragraph(
            current,
            current_size.unwrap_or(profile.body_size),
            current_left,
            heading_left_limit,
            profile,
        ));
    }
    paragraphs
}

fn render_paragraph(
    text: String,
    size: f32,
    left: f32,
    heading_left_limit: f32,
    profile: &FontProfile,
) -> String {
    if profile
        .title_size
        .is_some_and(|title_size| (size - title_size).abs() <= 0.16)
    {
        format!("# {text}")
    } else if size > profile.body_size * 1.05 && left <= heading_left_limit {
        format!("## {text}")
    } else {
        text
    }
}

#[cfg(test)]
mod tests {
    use super::normalize_tracked_text;

    #[test]
    fn tracked_letter_runs_join_when_spacing_or_span_width_shows_tracking() {
        let spaced = "a n g e l o  c o r v i t t o";
        assert_eq!(normalize_tracked_text(spaced, 0.4, 8.8, 40.0), "angelo corvitto");
        assert_eq!(normalize_tracked_text(spaced, 0.0, 8.8, 108.1), "angelo corvitto");
        assert_eq!(normalize_tracked_text(spaced, 0.0, 8.8, 40.0), spaced);
    }
}
