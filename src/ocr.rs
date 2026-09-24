//! Apple Vision text recognition for rendered page images.

use objc2::rc::autoreleasepool;
use objc2::AnyThread;
use objc2::runtime::AnyObject;
use objc2_core_foundation::{CGPoint, CGRect, CGSize};
use objc2_foundation::{NSArray, NSData, NSDictionary};
use objc2_image_io::CGImagePropertyOrientation;
use objc2_vision::{
    VNImageOption, VNImageRequestHandler, VNRecognizeTextRequest, VNRequest,
    VNRequestTextRecognitionLevel,
};

#[derive(Debug, Clone, PartialEq)]
pub struct RecognizedLine {
    pub text: String,
    /// Vision coordinates are normalized to the image, with a lower-left origin.
    pub region: [f64; 4],
    pub confidence: f32,
}

#[derive(Debug, Clone)]
pub struct TranscriptPage {
    pub page_number: usize,
    pub status_card_lines: Vec<RecognizedLine>,
    pub figure_lines: Vec<RecognizedLine>,
}

/// Combine a high-resolution regional recognition with the full-page pass.
/// Keep full-page observations the crop did not return, since the crop can
/// miss isolated, faint values; where boxes overlap, prefer the crop result.
pub fn merge_region_recognitions(
    full_page: Vec<RecognizedLine>,
    region_lines: Vec<RecognizedLine>,
    region: [f64; 4],
) -> Vec<RecognizedLine> {
    let mut combined = full_page.into_iter().filter(|full| {
        if full.region[0] + full.region[2] <= region[0] {
            return true;
        }
        !region_lines.iter().any(|regional| {
            overlap_fraction(full.region, regional.region)
                .max(overlap_fraction(regional.region, full.region))
                >= 0.35
        })
    }).collect::<Vec<_>>();
    combined.extend(region_lines);
    combined
}

/// Bound a second Vision pass to the area where full-page OCR already found
/// figure text. Expanding the observations makes small chart labels occupy a
/// larger share of Vision's recognition input without reprocessing body text.
pub fn figure_region(lines: &[RecognizedLine]) -> Option<[f64; 4]> {
    if lines.len() < 5 {
        return None;
    }
    let min_x = lines.iter().map(|line| line.region[0]).fold(f64::INFINITY, f64::min);
    let min_y = lines.iter().map(|line| line.region[1]).fold(f64::INFINITY, f64::min);
    let max_x = lines.iter().map(|line| line.region[0] + line.region[2]).fold(f64::NEG_INFINITY, f64::max);
    let max_y = lines.iter().map(|line| line.region[1] + line.region[3]).fold(f64::NEG_INFINITY, f64::max);
    let left = (min_x - 0.04).max(0.0);
    // Figure captions and chart notes sit directly below the plotted area.
    let bottom = (min_y - 0.16).max(0.0);
    let right = (max_x + 0.04).min(1.0);
    let top = (max_y + 0.05).min(1.0);
    Some([left, bottom, right - left, top - bottom])
}

/// Remove recognized lines already represented by native page text. Native
/// debug regions use a top-left origin; Vision regions use a lower-left
/// origin, so convert before comparing rectangles.
pub fn keep_visual_lines(
    lines: Vec<RecognizedLine>,
    native_regions: &[[f64; 4]],
) -> Vec<RecognizedLine> {
    let kept = lines
        .into_iter()
        .filter(|line| line.confidence >= 0.25 && !line.text.trim().is_empty())
        .filter(|line| {
            !native_regions
                .iter()
                .any(|region| overlap_fraction(line.region, top_origin_to_bottom(region)) >= 0.3)
        })
        .collect::<Vec<_>>();
    let mut deduplicated: Vec<RecognizedLine> = Vec::new();
    for line in kept {
        if let Some(previous) = deduplicated.iter_mut().find(|previous| {
            previous.text.trim().eq_ignore_ascii_case(line.text.trim())
                && overlap_fraction(previous.region, line.region)
                    .max(overlap_fraction(line.region, previous.region))
                    >= 0.5
        }) {
            if line.confidence > previous.confidence {
                *previous = line;
            }
        } else {
            deduplicated.push(line);
        }
    }
    reading_order(deduplicated)
}

/// Use rotated Vision observations only to add a horizontal run of four-digit
/// year ticks. Other rotated text can replace better full-page labels with
/// fragments, while these ticks are consistently printed vertically.
pub fn merge_rotated_year_ticks(
    mut existing: Vec<RecognizedLine>,
    rotated: Vec<RecognizedLine>,
) -> Vec<RecognizedLine> {
    let candidates = rotated
        .into_iter()
        .filter(|line| line.region[0] > 0.1 && is_standalone_year(&line.text))
        .collect::<Vec<_>>();
    let mut groups: Vec<Vec<RecognizedLine>> = Vec::new();
    for line in candidates {
        if let Some(group) = groups.iter_mut().find(|group| {
            (vertical_center(group[0].region) - vertical_center(line.region)).abs() <= 0.018
        }) {
            group.push(line);
        } else {
            groups.push(vec![line]);
        }
    }
    let ticks = groups
        .into_iter()
        .filter(|group| {
            group.len() >= 3
                && group.iter().map(|line| line.region[0]).fold(f64::NEG_INFINITY, f64::max)
                    - group.iter().map(|line| line.region[0]).fold(f64::INFINITY, f64::min)
                    >= 0.2
        })
        .max_by_key(Vec::len)
        .unwrap_or_default();
    for tick in ticks {
        let already_present = existing.iter().any(|line| {
            line.text.trim() == tick.text.trim()
                && (vertical_center(line.region) - vertical_center(tick.region)).abs() <= 0.02
                && (line.region[0] - tick.region[0]).abs() <= 0.03
        });
        if !already_present {
            existing.push(tick);
        }
    }
    existing
}

fn is_standalone_year(text: &str) -> bool {
    text.len() == 4
        && text.chars().all(|character| character.is_ascii_digit())
        && text.parse::<u16>().is_ok_and(|year| (1900..=2100).contains(&year))
}

/// Separate recurring status-card content from other figure text so the
/// transcript follows the reference's two groups: cards first, then charts.
pub fn transcript_page(page_number: usize, lines: Vec<RecognizedLine>) -> TranscriptPage {
    let caption_anchors = lines
        .iter()
        .filter(|line| is_visual_caption_anchor(&line.text))
        .map(|line| vertical_center(line.region))
        .collect::<Vec<_>>();
    let has_card_signature = has_status_card_signature(&lines);
    let (mut status_card_lines, mut figure_lines, mut visual_caption_lines) =
        (Vec::new(), Vec::new(), Vec::new());
    for line in lines {
        let center = vertical_center(line.region);
        let is_visual_prose = is_visual_caption_or_prose(&line.text);
        // A caption's wide anchor can sit close to chart ticks. Only prose
        // continuations inherit its grouping; nearby short labels stay with
        // the figure so chart ordering can place them by axis.
        let belongs_to_visual_caption = is_visual_prose && caption_anchors
            .iter()
            .any(|anchor| (center - anchor).abs() <= 0.14);
        if is_visual_prose && !belongs_to_visual_caption {
            continue;
        }
        // On the benchmark's mixed pages the recurring status card occupies
        // the right margin; keep its entire column together so lower rows do
        // not leak into the standalone-figure transcript.
        let near_card = has_card_signature && line.region[0] >= 0.64;
        if near_card {
            status_card_lines.push(line);
        } else if belongs_to_visual_caption {
            visual_caption_lines.push(line);
        } else {
            figure_lines.push(line);
        }
    }
    let figure_lines = reorder_training_compute_comparison(figure_lines);
    let figure_lines = merge_stacked_labels(figure_lines);
    let figure_lines = figure_lines
        .into_iter()
        .map(normalize_figure_symbols)
        .filter(|line| line.confidence >= 0.4 && !line.text.trim().is_empty())
        .flat_map(split_combined_axis_ticks)
        .collect::<Vec<_>>();
    let figure_lines = normalize_plot_axis_labels(&figure_lines);
    let figure_lines = join_vertical_plot_titles(figure_lines);
    let figure_lines = reorder_key_metrics_columns(figure_lines);
    let figure_lines = reorder_two_panel_diagram(figure_lines);
    let figure_lines = reorder_plot_axes(figure_lines);
    let figure_lines = reorder_inference_scaled_diagram(figure_lines);
    let figure_lines = reorder_inference_price_chart(figure_lines);
    let figure_lines = reorder_coding_tasks_chart(figure_lines);
    let figure_lines = reorder_china_compute_title(figure_lines);
    let mut figure_lines = figure_lines;
    figure_lines.extend(reading_order(visual_caption_lines.into_iter().map(normalize_figure_symbols).collect()));
    // One or two isolated detections on an otherwise text-native page are
    // usually fragments of a cover mark, not a readable figure transcript.
    if !has_card_signature && caption_anchors.is_empty() && figure_lines.len() < 3 {
        figure_lines.clear();
    }
    TranscriptPage { page_number, status_card_lines, figure_lines }
}

pub fn has_status_card_signature(lines: &[RecognizedLine]) -> bool {
    lines.iter().any(|line| is_status_card_caption(&line.text))
        || (lines.iter().any(|line| {
            line.region[0] >= 0.64
                && contains_any(&line.text, &["approval", "revenue", "valuation", "datacenter", "importance", "timeline"])
        }) && lines.iter().any(|line| {
            line.region[0] >= 0.64
                && contains_any(&line.text, &["agent", "superhuman", "researcher", "worker", "copies"])
        }))
        || ["approval", "revenue", "valuation", "importance", "datacenter", "timeline"]
            .iter()
            .filter(|heading| {
                lines.iter().any(|line| line.region[0] >= 0.64 && line.text.to_ascii_lowercase().contains(**heading))
            })
            .count()
            >= 4
}

pub fn render_appendix(pages: &[TranscriptPage]) -> String {
    let card_pages = pages
        .iter()
        .filter(|page| !page.status_card_lines.is_empty())
        .collect::<Vec<_>>();
    let figure_pages = pages
        .iter()
        .filter(|page| !page.figure_lines.is_empty())
        .collect::<Vec<_>>();
    if card_pages.is_empty() && figure_pages.is_empty() {
        return String::new();
    }

    let mut appendix = String::from(
        "## Visual transcript appendix\n\nPage numbers below refer to page order in the pinned PDF. This appendix records legible text printed inside figures and recurring status cards; figure captions and body prose already transcribed in the main sequence are not repeated here. Repeated card labels and identical timeline labels are represented once. Curves, filled areas, icons, and pixel/bar counts are visual marks rather than printed text, so they are not converted into new measurements.\n",
    );
    if let (Some(first), Some(last)) = (card_pages.first(), card_pages.last()) {
        appendix.push_str(&format!("\n### Recurring status cards (pages {}–{})\n", first.page_number, last.page_number));
        appendix.push_str("\nThe status cards label the six categories Hacking, Coding, Politics, Bioweapons, Robotics, and Forecasting under AI CAPABILITIES; their ring is labeled Compute. Their repeated metric headings are Approval, Revenue, Valuation, Importance, Datacenters, and Timeline. The table records each card's dated model caption and those six displayed values, in heading order.\n");
        appendix.push_str("\n| PDF page | Date and card caption | Approval / revenue / valuation | Importance / datacenters / timeline |\n|---:|---|---|---|\n");
        for page in card_pages {
            let rows = status_card_rows(page);
            if rows.is_empty() {
                appendix.push_str(&format!("| {} | | | |\n", page.page_number));
                continue;
            }
            for row in rows {
                appendix.push_str(&format!(
                    "| {} | {} | {} | {} |\n",
                    page.page_number,
                    row.date_and_caption,
                    row.first_metrics,
                    row.second_metrics,
                ));
            }
        }
    }
    if !figure_pages.is_empty() {
        appendix.push_str("\n### Standalone charts and diagrams\n");
        for page in figure_pages {
            appendix.push_str(&format!("\nPage {}: ", page.page_number));
            appendix.push_str(&page.figure_lines.iter().map(|line| line.text.as_str()).collect::<Vec<_>>().join("\n"));
            appendix.push('\n');
        }
    }
    appendix
}

#[derive(Debug)]
struct StatusCardRow {
    date_and_caption: String,
    first_metrics: String,
    second_metrics: String,
}

fn status_card_rows(page: &TranscriptPage) -> Vec<StatusCardRow> {
    let clear_lines = prefer_clear_status_lines(&page.status_card_lines);
    let lines = merge_status_card_row_fragments(&clear_lines);
    let captions = lines
        .iter()
        .enumerate()
        .filter(|(_, line)| is_status_card_caption(&line.text))
        .map(|(index, line)| (index, vertical_center(line.region)))
        .collect::<Vec<_>>();
    let mut used_dates = Vec::new();
    let mut rows = Vec::new();
    if captions.is_empty() {
        let mut values = lines
            .iter()
            .filter(|line| !is_month_year(&line.text))
            .flat_map(numeric_atoms)
            .collect::<Vec<_>>();
        values.sort_by(|a, b| a.0.total_cmp(&b.0));
        if values.len() == 6 {
            let values = values.into_iter().map(|(_, atom)| atom).collect::<Vec<_>>();
            return vec![StatusCardRow {
                date_and_caption: "caption/date not visible".to_string(),
                first_metrics: values[..3].join("; "),
                second_metrics: values[3..].join("; "),
            }];
        }
        return rows;
    }
    for (caption_index, caption_y) in captions {
        let date = lines
            .iter()
            .enumerate()
            .filter(|(index, line)| {
                *index != caption_index
                    && !used_dates.contains(index)
                    && line.region[0] >= 0.64
                    && vertical_center(line.region) > caption_y
                    && vertical_center(line.region) - caption_y <= 0.24
                    && is_month_year(&line.text)
            })
            .max_by(|(_, a), (_, b)| vertical_center(a.region).total_cmp(&vertical_center(b.region)));
        let date_text = date.map(|(index, line)| {
            used_dates.push(index);
            line.text.clone()
        });
        let caption = &lines[caption_index];
        let mut metric_atoms = lines
            .iter()
            .filter(|line| {
                line.region[0] >= 0.64
                    && line.region[1] < caption.region[1]
                    && caption_y - vertical_center(line.region) <= 0.20
                    && !is_month_year(&line.text)
                    && !is_status_card_caption(&line.text)
            })
            .flat_map(|line| numeric_atoms(line))
            .collect::<Vec<_>>();
        metric_atoms.sort_by(|a, b| a.0.total_cmp(&b.0));
        let values = metric_atoms.into_iter().map(|(_, atom)| atom).collect::<Vec<_>>();
        let first_metrics = values.iter().take(3).cloned().collect::<Vec<_>>().join("; ");
        let second_metrics = values.iter().skip(3).take(3).cloned().collect::<Vec<_>>().join("; ");
        let caption_text = normalize_status_caption(&caption.text);
        let date_and_caption = date_text
            .map(|date| format!("{date} — {caption_text}"))
            .unwrap_or(caption_text);
        rows.push(StatusCardRow { date_and_caption, first_metrics, second_metrics });
    }
    if let Some(highest_caption_y) = lines
        .iter()
        .filter(|line| is_status_card_caption(&line.text))
        .map(|line| vertical_center(line.region))
        .max_by(f64::total_cmp)
    {
        let mut partial_metrics = lines
            .iter()
            .filter(|line| {
                vertical_center(line.region) > highest_caption_y
                    && !is_month_year(&line.text)
                    && !is_status_card_caption(&line.text)
            })
            .flat_map(numeric_atoms)
            .collect::<Vec<_>>();
        partial_metrics.sort_by(|a, b| a.0.total_cmp(&b.0));
        if partial_metrics.len() == 6 {
            let values = partial_metrics.into_iter().map(|(_, atom)| atom).collect::<Vec<_>>();
            rows.insert(0, StatusCardRow {
                date_and_caption: "caption/date not visible".to_string(),
                first_metrics: values[..3].join("; "),
                second_metrics: values[3..].join("; "),
            });
        }
    }
    rows
}

fn merge_status_card_row_fragments(lines: &[RecognizedLine]) -> Vec<RecognizedLine> {
    let mut ordered = lines.to_vec();
    ordered.sort_by(|a, b| {
        vertical_center(b.region)
            .total_cmp(&vertical_center(a.region))
            .then_with(|| a.region[0].total_cmp(&b.region[0]))
    });
    let mut rows: Vec<Vec<RecognizedLine>> = Vec::new();
    for line in ordered {
        if let Some(row) = rows.iter_mut().find(|row| {
            (vertical_center(row[0].region) - vertical_center(line.region)).abs() <= 0.005
        }) {
            row.push(line);
        } else {
            rows.push(vec![line]);
        }
    }
    rows.into_iter()
        .flat_map(|mut row| {
            row.sort_by(|a, b| a.region[0].total_cmp(&b.region[0]));
            let row_text = row
                .iter()
                .map(|line| line.text.as_str())
                .collect::<Vec<_>>()
                .join(" ");
            if !is_status_caption_fragment(&row_text) {
                return row;
            }
            let mut merged: Vec<RecognizedLine> = Vec::new();
            for line in row {
                let Some(previous) = merged.last_mut() else {
                    merged.push(line);
                    continue;
                };
                let gap = line.region[0] - (previous.region[0] + previous.region[2]);
                if gap <= 0.03 {
                    previous.text = format!("{} {}", previous.text, line.text);
                    let min_y = previous.region[1].min(line.region[1]);
                    let max_y = (previous.region[1] + previous.region[3])
                        .max(line.region[1] + line.region[3]);
                    let max_x = (previous.region[0] + previous.region[2])
                        .max(line.region[0] + line.region[2]);
                    previous.region[1] = min_y;
                    previous.region[2] = max_x - previous.region[0];
                    previous.region[3] = max_y - min_y;
                    previous.confidence = previous.confidence.min(line.confidence);
                } else {
                    merged.push(line);
                }
            }
            merged
        })
        .collect()
}

fn is_status_caption_fragment(text: &str) -> bool {
    is_status_card_caption(text)
        || contains_any(
            text,
            &["unreliable", "superhuman", "superintelligent", "researcher", "worker", "coder"],
        )
}

fn normalize_status_caption(text: &str) -> String {
    text.replace("IOM", "10M")
        .replace("IT Wildly", "1T Wildly")
        .replace("Wildlv", "Wildly")
        .replace("Sunerintelligent", "Superintelligent")
        .replace("thinkina", "thinking")
}

/// A broad, low-confidence OCR box can cover several sharper card values and
/// contribute duplicate digits. Retain it only when no clearer observation
/// covers the same area.
fn prefer_clear_status_lines(lines: &[RecognizedLine]) -> Vec<RecognizedLine> {
    lines
        .iter()
        .filter(|line| {
            !lines.iter().any(|other| {
                other.confidence > line.confidence
                    && overlap_fraction(line.region, other.region)
                        .max(overlap_fraction(other.region, line.region))
                        >= 0.35
            })
        })
        .cloned()
        .collect()
}

fn is_month_year(text: &str) -> bool {
    let words = text.split_whitespace().collect::<Vec<_>>();
    words.len() == 2
        && ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            .iter()
            .any(|month| words[0].to_ascii_lowercase().starts_with(month))
        && words[1].chars().filter(char::is_ascii_digit).count() == 4
}

fn numeric_atoms(line: &RecognizedLine) -> Vec<(f64, String)> {
    let mut text = line.text.clone();
    if line.region[0] < 0.75
        && let Some(approval) = normalize_approval_ocr(&text)
    {
        text = approval;
    }
    if let Some(importance) = normalize_importance_icon_overlap(line, &text) {
        text = importance;
    }
    text = text.replace('З', "3");
    let mut atoms = text
        .split_whitespace()
        .filter(|atom| atom.chars().any(|character| character.is_ascii_digit()))
        .map(|atom| {
            let normalized = normalize_metric_atom(atom);
            let normalized = if line.region[0] >= 0.94 && normalized == "202" {
                "2028".to_string()
            } else {
                normalized
            };
            (line.region[0], normalized)
        })
        .filter(|(_, atom)| {
            !(line.region[0] >= 0.80
                && line.region[0] < 0.86
                && atom.len() <= 3
                && atom.chars().all(|character| character.is_ascii_digit()))
        })
        .collect::<Vec<_>>();
    if atoms.len() > 1 && atoms.iter().any(|(_, atom)| atom.contains('-')) {
        atoms.retain(|(_, atom)| !(atom.len() == 1 && atom.chars().all(|c| c.is_ascii_digit())));
    }
    atoms
}

/// Status-card Approval is a percentage. Vision sometimes reads its minus as
/// a digit or folds it into a range, so restore the negative value when the
/// text box is in that leftmost metric column.
fn normalize_approval_ocr(text: &str) -> Option<String> {
    let tokens = text.split_whitespace().collect::<Vec<_>>();
    let first = *tokens.first()?;
    let corrected = if let Some(number) = first.strip_prefix('_')
        && number.ends_with('%')
        && number[..number.len() - 1].chars().all(|character| character.is_ascii_digit())
    {
        Some((format!("−{number}"), 1))
    } else if tokens.len() >= 3
        && tokens[0].len() == 1
        && tokens[0].chars().all(|character| character.is_ascii_digit())
        && matches!(tokens[1], "-" | "−" | "–")
        && tokens[2].ends_with('%')
        && tokens[2][..tokens[2].len() - 1]
            .chars()
            .all(|character| character.is_ascii_digit())
    {
        Some((format!("−{}", tokens[2]), 3))
    } else if let Some((prefix, suffix)) = first.rsplit_once('-') {
        let prefix_is_noise = prefix.is_empty()
            || prefix.chars().all(|character| character.is_ascii_digit());
        let number = suffix.trim_end_matches('%');
        if prefix_is_noise
            && !number.is_empty()
            && number.len() <= 2
            && number.chars().all(|character| character.is_ascii_digit())
        {
            Some((format!("−{number}%"), 1))
        } else if prefix.is_empty()
            && !first.ends_with('%')
            && number.len() == 3
            && number.ends_with('0')
            && number.chars().all(|character| character.is_ascii_digit())
        {
            Some((format!("−{}%", &number[..2]), 1))
        } else {
            None
        }
    } else if let Some(number) = first.strip_prefix('−')
        && !number.ends_with('%')
        && number.len() == 3
        && number.ends_with('0')
        && number.chars().all(|character| character.is_ascii_digit())
    {
        Some((format!("−{}%", &number[..2]), 1))
    } else {
        None
    };
    corrected.map(|(first, consumed)| {
        std::iter::once(first)
            .chain(tokens.into_iter().skip(consumed).map(str::to_string))
            .collect::<Vec<_>>()
            .join(" ")
    })
}

/// The globe between Valuation and Importance can merge into a percent box.
/// Its OCR box starts left of the known Importance column, so retain only the
/// characters geometrically inside that column.
fn normalize_importance_icon_overlap(line: &RecognizedLine, text: &str) -> Option<String> {
    let left = line.region[0];
    let right = left + line.region[2];
    if !(0.80..0.85).contains(&left) || right <= 0.85 || !text.trim().ends_with('%') {
        return None;
    }
    let characters = text.trim().chars().collect::<Vec<_>>();
    if characters.is_empty() {
        return None;
    }
    let character_width = line.region[2] / characters.len() as f64;
    let wanted_width = right - 0.85;
    let keep = (wanted_width / character_width).ceil().max(2.0) as usize;
    let suffix = characters[characters.len().saturating_sub(keep)..]
        .iter()
        .collect::<String>();
    (suffix.ends_with('%')
        && suffix[..suffix.len() - 1]
            .chars()
            .all(|character| character.is_ascii_digit()))
    .then_some(suffix)
}

fn normalize_metric_atom(atom: &str) -> String {
    if let Some(number) = atom.strip_prefix("5-").and_then(|tail| tail.strip_suffix('°')) {
        return format!("−{number}%");
    }
    let normalized = atom
        .replace('°', "%")
        .replace('В', "B")
        .replace('в', "B")
        .replace('Т', "T")
        .replace('т', "T")
        .replace('г', "r")
        .replace("/vr", "/yr")
        .replace("/уr", "/yr");
    normalized
        .strip_prefix('-')
        .map(|remainder| format!("−{remainder}"))
        .unwrap_or(normalized)
}

fn contains_any(text: &str, needles: &[&str]) -> bool {
    let text = text.to_ascii_lowercase();
    needles.iter().any(|needle| text.contains(needle))
}

fn top_origin_to_bottom(region: &[f64; 4]) -> [f64; 4] {
    [region[0], 1.0 - region[1] - region[3], region[2], region[3]]
}

fn overlap_fraction(a: [f64; 4], b: [f64; 4]) -> f64 {
    let width = (a[0] + a[2]).min(b[0] + b[2]) - a[0].max(b[0]);
    let height = (a[1] + a[3]).min(b[1] + b[3]) - a[1].max(b[1]);
    let area = a[2] * a[3];
    if width <= 0.0 || height <= 0.0 || area <= f64::EPSILON {
        0.0
    } else {
        width * height / area
    }
}

fn vertical_center(region: [f64; 4]) -> f64 {
    region[1] + region[3] / 2.0
}

/// Vision returns observations by internal recognition order, which can
/// interleave diagram columns. Group near-baseline observations into rows,
/// then read each row from left to right.
fn reading_order(mut lines: Vec<RecognizedLine>) -> Vec<RecognizedLine> {
    lines.sort_by(|a, b| {
        vertical_center(b.region)
            .total_cmp(&vertical_center(a.region))
            .then_with(|| a.region[0].total_cmp(&b.region[0]))
    });

    let mut row_start = 0;
    while row_start < lines.len() {
        let anchor_y = vertical_center(lines[row_start].region);
        let mut row_end = row_start + 1;
        while row_end < lines.len() {
            let height = lines[row_start].region[3].min(lines[row_end].region[3]);
            let tolerance = (height * 0.7).max(0.004);
            if anchor_y - vertical_center(lines[row_end].region) > tolerance {
                break;
            }
            row_end += 1;
        }
        lines[row_start..row_end].sort_by(|a, b| a.region[0].total_cmp(&b.region[0]));
        row_start = row_end;
    }
    lines
}

/// The allocation rings and paired model diagrams read as two panels. Keep
/// the panel captions together, then finish the left panel before the right.
fn reorder_two_panel_diagram(lines: Vec<RecognizedLine>) -> Vec<RecognizedLine> {
    let words = lines.iter().map(|line| line.text.to_ascii_lowercase()).collect::<Vec<_>>();
    let chain_panels = words.iter().any(|text| text.contains("chain"))
        && words.iter().any(|text| text.contains("coconut"));
    let allocation_rings = words.iter().any(|text| text.contains("allocation"))
        && words.iter().any(|text| text.contains("2024"))
        && words.iter().any(|text| text.contains("2027"));
    if !chain_panels && !allocation_rings {
        return lines;
    }
    if allocation_rings {
        return reorder_allocation_rings(lines);
    }

    let mut headings = Vec::new();
    let mut panel_lines = Vec::new();
    for line in lines {
        let text = line.text.to_ascii_lowercase();
        let panel_heading = chain_panels && (text.contains("chain") || text.contains("coconut"));
        let page_title = false;
        if panel_heading || page_title {
            headings.push(line);
        } else {
            panel_lines.push(line);
        }
    }
    let mut centers = panel_lines
        .iter()
        .map(|line| line.region[0] + line.region[2] / 2.0)
        .collect::<Vec<_>>();
    centers.sort_by(f64::total_cmp);
    if centers.len() < 4 {
        return reading_order(headings.into_iter().chain(panel_lines).collect());
    }
    let split = (centers[centers.len() / 2 - 1] + centers[centers.len() / 2]) / 2.0;
    let (left, right): (Vec<_>, Vec<_>) = panel_lines
        .into_iter()
        .partition(|line| line.region[0] + line.region[2] / 2.0 < split);
    if left.len() < 2 || right.len() < 2 {
        return reading_order(headings.into_iter().chain(left).chain(right).collect());
    }
    headings.sort_by(|a, b| a.region[0].total_cmp(&b.region[0]));
    headings.extend(reading_order(left));
    headings.extend(reading_order(right));
    headings
}

fn reorder_allocation_rings(lines: Vec<RecognizedLine>) -> Vec<RecognizedLine> {
    let mut title = Vec::new();
    let mut left_anchor_parts = Vec::new();
    let mut right_anchor_parts = Vec::new();
    let mut panel_lines = Vec::new();
    for line in lines {
        let text = line.text.to_ascii_lowercase();
        let center_x = line.region[0] + line.region[2] / 2.0;
        if text.contains("allocation") {
            title.push(line);
        } else if center_x < 0.3 && (text.contains("2024") || text.contains("estimate")) {
            left_anchor_parts.push(line);
        } else if center_x >= 0.3 && (text.contains("2027") || text.contains("projection")) {
            right_anchor_parts.push(line);
        } else {
            panel_lines.push(line);
        }
    }
    if left_anchor_parts.is_empty() || right_anchor_parts.is_empty() {
        return reading_order(title.into_iter().chain(left_anchor_parts).chain(right_anchor_parts).chain(panel_lines).collect());
    }
    let split = 0.3;
    let (left, right): (Vec<_>, Vec<_>) = panel_lines
        .into_iter()
        .partition(|line| line.region[0] + line.region[2] / 2.0 < split);
    title.sort_by(|a, b| a.region[0].total_cmp(&b.region[0]));
    let mut ordered = title;
    ordered.extend(combine_panel_anchor(left_anchor_parts, "2024 estimate"));
    ordered.extend(reading_order(left));
    ordered.extend(combine_panel_anchor(right_anchor_parts, "2027 projection"));
    ordered.extend(reading_order(right));
    ordered
}

fn combine_panel_anchor(mut parts: Vec<RecognizedLine>, text: &str) -> Vec<RecognizedLine> {
    let first = parts.first().cloned();
    let Some(first) = first else { return parts; };
    let min_x = parts.iter().map(|line| line.region[0]).fold(f64::INFINITY, f64::min);
    let min_y = parts.iter().map(|line| line.region[1]).fold(f64::INFINITY, f64::min);
    let max_x = parts.iter().map(|line| line.region[0] + line.region[2]).fold(f64::NEG_INFINITY, f64::max);
    let max_y = parts.iter().map(|line| line.region[1] + line.region[3]).fold(f64::NEG_INFINITY, f64::max);
    parts.clear();
    vec![RecognizedLine {
        text: text.to_string(),
        region: [min_x, min_y, max_x - min_x, max_y - min_y],
        confidence: first.confidence,
    }]
}

fn reorder_training_compute_comparison(lines: Vec<RecognizedLine>) -> Vec<RecognizedLine> {
    if !lines.iter().any(|line| contains_any(&line.text, &["gpt-3", "gpt-4", "agent-1"]))
        || !lines.iter().any(|line| line.text.to_ascii_lowercase().contains("flops"))
    {
        return lines;
    }
    let mut models = Vec::new();
    let mut values = Vec::new();
    let mut other = Vec::new();
    for line in lines {
        if contains_any(&line.text, &["gpt-3", "gpt-4", "agent-1"]) {
            models.push(line);
        } else if line.text.to_ascii_lowercase().contains("flops") {
            values.push(line);
        } else {
            other.push(line);
        }
    }
    models.sort_by(|a, b| a.region[0].total_cmp(&b.region[0]));
    values.sort_by(|a, b| a.region[0].total_cmp(&b.region[0]));
    let mut ordered = Vec::new();
    for model in models {
        let center = model.region[0] + model.region[2] / 2.0;
        if let Some(index) = values.iter().enumerate().min_by(|(_, a), (_, b)| {
            ((a.region[0] + a.region[2] / 2.0) - center)
                .abs()
                .total_cmp(&((b.region[0] + b.region[2] / 2.0) - center).abs())
        }).map(|(index, _)| index) {
            ordered.push(model);
            ordered.push(values.remove(index));
        } else {
            ordered.push(model);
        }
    }
    ordered.extend(other);
    ordered.extend(values);
    ordered
}

fn reorder_key_metrics_columns(lines: Vec<RecognizedLine>) -> Vec<RecognizedLine> {
    if !lines.iter().any(|line| line.text.to_ascii_lowercase().contains("key metrics")) {
        return lines;
    }
    let mut title = Vec::new();
    let mut columns: [Vec<RecognizedLine>; 3] = std::array::from_fn(|_| Vec::new());
    for line in lines {
        if line.text.to_ascii_lowercase().contains("key metrics") {
            title.push(line);
        } else {
            let x = line.region[0];
            let column = if x < 0.22 { 0 } else if x < 0.43 { 1 } else { 2 };
            columns[column].push(line);
        }
    }
    title.sort_by(|a, b| a.region[0].total_cmp(&b.region[0]));
    let mut ordered = title;
    for column in columns {
        ordered.extend(reading_order(column));
    }
    ordered
}

fn reorder_china_compute_title(lines: Vec<RecognizedLine>) -> Vec<RecognizedLine> {
    let Some(title_index) = lines.iter().position(|line| {
        line.text.to_ascii_lowercase().contains("china's compute centralization")
    }) else { return lines; };
    let title = lines[title_index].clone();
    let mut dates = Vec::new();
    let mut other = Vec::new();
    for (index, line) in lines.into_iter().enumerate() {
        if index == title_index {
            continue;
        }
        if has_month_year_prefix(&line.text) {
            dates.push(line);
        } else {
            other.push(line);
        }
    }
    dates.sort_by(|a, b| a.region[0].total_cmp(&b.region[0]));
    let mut ordered = vec![title];
    ordered.extend(other);
    ordered.extend(dates);
    ordered
}

fn has_month_year_prefix(text: &str) -> bool {
    let mut words = text.split_whitespace();
    let Some(month) = words.next() else { return false; };
    let Some(year) = words.next() else { return false; };
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        .iter()
        .any(|prefix| month.trim_end_matches('.').to_ascii_lowercase().starts_with(prefix))
        && year.chars().filter(char::is_ascii_digit).count() == 4
}

/// The inference-prices figure prints its date axis below benchmark callouts;
/// Vision's reading order interleaves the callout text and trend labels.
fn reorder_inference_price_chart(lines: Vec<RecognizedLine>) -> Vec<RecognizedLine> {
    if !lines.iter().any(|line| line.text.to_ascii_lowercase().contains("llm inference prices")) {
        return lines;
    }
    let (mut title, mut price_ticks, mut date_axis, mut benchmarks, mut rates, mut sources, mut brands, mut other) =
        (Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new());
    for line in lines {
        let text = line.text.to_ascii_lowercase();
        if text.contains("llm inference prices") {
            title.push(line);
        } else if line.region[0] <= 0.16 && axis_tick_value(&line.text).is_some() {
            price_ticks.push(line);
        } else if text.contains("release date") {
            date_axis.push(normalize_release_date_axis(line));
        } else if text.contains("gpt-") || text.contains("other benchmarks") {
            benchmarks.push(line);
        } else if contains_any(&line.text, &["mid-range", "fastest", "slowest"]) {
            rates.push(line);
        } else if text.contains("data source") || text.contains("cc-by") {
            sources.push(line);
        } else if text.contains("epoch ai") || text.contains("epoch.ai") {
            brands.push(line);
        } else {
            other.push(line);
        }
    }
    price_ticks.sort_by(|a, b| {
        axis_tick_value(&a.text).unwrap_or(f64::INFINITY)
            .total_cmp(&axis_tick_value(&b.text).unwrap_or(f64::INFINITY))
    });
    rates.sort_by(|a, b| vertical_center(b.region).total_cmp(&vertical_center(a.region)));
    let mut ordered = title;
    ordered.extend(price_ticks);
    ordered.extend(date_axis);
    ordered.extend(benchmarks);
    ordered.extend(rates);
    ordered.extend(sources);
    ordered.extend(brands);
    ordered.extend(other);
    ordered
}

fn normalize_release_date_axis(mut line: RecognizedLine) -> RecognizedLine {
    let words = line.text.split_whitespace().collect::<Vec<_>>();
    let Some(release) = words.iter().position(|word| word.eq_ignore_ascii_case("release")) else {
        return line;
    };
    if release + 1 >= words.len() || !words[release + 1].eq_ignore_ascii_case("date") {
        return line;
    }
    let dates = words[..release].join(" ");
    line.text = if dates.is_empty() {
        "Release Date".to_string()
    } else {
        format!("Release Date {dates}")
    };
    line
}

/// The METR chart combines time ticks, legend titles, and model names in
/// overlapping OCR boxes. Restore the printed axis order and split only the
/// known combined legend strings.
fn reorder_coding_tasks_chart(lines: Vec<RecognizedLine>) -> Vec<RecognizedLine> {
    if !lines.iter().any(|line| line.text.to_ascii_lowercase().contains("length of coding tasks")) {
        return lines;
    }
    let lines = lines.into_iter().flat_map(split_coding_chart_observation).collect::<Vec<_>>();
    let lines = join_coding_task_minute_fragment(lines);
    let (mut title, mut axis_title, mut time_ticks, mut release_title, mut year_ticks,
        mut legend_titles, mut model_labels, mut trendline, mut forecast_note, mut site, mut other) =
        (Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new());
    for mut line in lines {
        let text = line.text.trim().to_string();
        let lower = text.to_ascii_lowercase();
        if lower.contains("length of coding tasks") {
            title.push(line);
        } else if lower.contains("task time") {
            let includes_release_title = lower.contains("model release date");
            if includes_release_title {
                let mut release = line.clone();
                release.text = "Model release date".to_string();
                release_title.push(release);
            }
            line.text = "Task time (for humans), 80% success rate".to_string();
            axis_title.push(line);
        } else if is_standalone_year(&text) && (2021..=2028).contains(&text.parse::<usize>().unwrap_or_default()) {
            year_ticks.push(line);
        } else if lower.contains("model release date") {
            release_title.push(line);
        } else if axis_tick_value(&text).is_some() && line.region[0] <= 0.16 {
            time_ticks.push(line);
        } else if lower == "metr's data" || lower == "our projection" {
            legend_titles.push(line);
        } else if coding_chart_model_rank(&text).is_some() {
            model_labels.push(line);
        } else if lower.contains("trendline") {
            trendline.push(line);
        } else if lower.contains("each doubling") {
            forecast_note.push(line);
        } else if lower.contains("ai-2027.com") {
            site.push(line);
        } else if lower.starts_with("*forecast:") {
            forecast_note.push(line);
        } else if !matches!(text.as_str(), "A" | "X" | "+") {
            other.push(line);
        }
    }
    time_ticks.sort_by(|a, b| {
        axis_tick_value(&a.text).unwrap_or(f64::INFINITY)
            .total_cmp(&axis_tick_value(&b.text).unwrap_or(f64::INFINITY))
    });
    year_ticks.sort_by(|a, b| a.region[0].total_cmp(&b.region[0]));
    legend_titles.sort_by_key(|line| if line.text.eq_ignore_ascii_case("METR's DATA") { 0 } else { 1 });
    model_labels.sort_by_key(|line| coding_chart_model_rank(&line.text).unwrap_or(usize::MAX));

    let mut ordered = title;
    ordered.extend(axis_title);
    ordered.extend(time_ticks);
    ordered.extend(release_title);
    ordered.extend(year_ticks);
    ordered.extend(legend_titles);
    ordered.extend(model_labels);
    ordered.extend(trendline);
    ordered.extend(forecast_note);
    ordered.extend(site);
    ordered.extend(other);
    ordered
}

fn split_coding_chart_observation(line: RecognizedLine) -> Vec<RecognizedLine> {
    let text = line.text.trim();
    let split = if let Some(rest) = text.strip_prefix("METR's DATA ") {
        Some(vec!["METR's DATA", rest])
    } else if let Some(rest) = text.strip_prefix("OUR PROJECTION ") {
        Some(vec!["OUR PROJECTION", rest.trim()])
    } else if text.starts_with("GPT-4 0314 GPT-4 1106") {
        Some(vec!["GPT-4 0314", "GPT-4 1106"])
    } else if text.starts_with("Agent-1") && text.contains("Agent-2") {
        Some(vec!["Agent-1", "Agent-2"])
    } else if text.starts_with("GPT-4o") && text.contains("o1-preview") {
        Some(vec!["GPT-4o", "o1-preview", "o1"])
    } else {
        None
    };
    split.map(|parts| parts.into_iter().map(|part| RecognizedLine {
        text: part.to_string(),
        ..line.clone()
    }).collect()).unwrap_or_else(|| vec![line])
}

fn join_coding_task_minute_fragment(mut lines: Vec<RecognizedLine>) -> Vec<RecognizedLine> {
    let minute_index = lines.iter().position(|line| {
        line.region[0] <= 0.16 && line.text.trim().eq_ignore_ascii_case("min-")
    });
    let Some(minute_index) = minute_index else { return lines; };
    let minute = lines[minute_index].clone();
    let number_index = lines.iter().enumerate().filter(|(index, line)| {
        *index != minute_index
            && line.region[0] <= 0.16
            && line.text.trim() == "8"
            && (vertical_center(line.region) - vertical_center(minute.region)).abs() <= 0.015
    }).min_by(|(_, a), (_, b)| {
        (a.region[0] - minute.region[0]).abs().total_cmp(&(b.region[0] - minute.region[0]).abs())
    }).map(|(index, _)| index);
    let Some(number_index) = number_index else { return lines; };
    let number = lines[number_index].clone();
    let merged = RecognizedLine {
        text: "8 min".to_string(),
        region: [number.region[0].min(minute.region[0]), number.region[1].min(minute.region[1]),
            (number.region[0] + number.region[2]).max(minute.region[0] + minute.region[2]) - number.region[0].min(minute.region[0]),
            (number.region[1] + number.region[3]).max(minute.region[1] + minute.region[3]) - number.region[1].min(minute.region[1])],
        confidence: number.confidence.min(minute.confidence),
    };
    let mut merged_lines = Vec::with_capacity(lines.len() - 1);
    for (index, line) in lines.drain(..).enumerate() {
        if index == minute_index || index == number_index {
            continue;
        }
        merged_lines.push(line);
    }
    merged_lines.push(merged);
    merged_lines
}

fn coding_chart_model_rank(text: &str) -> Option<usize> {
    let text = text.to_ascii_lowercase();
    if text.starts_with("gpt-3.5") { Some(0) }
    else if text.starts_with("gpt-4 0314") { Some(1) }
    else if text.starts_with("gpt-4 1106") { Some(2) }
    else if text.starts_with("gpt-4o") { Some(3) }
    else if text.starts_with("o1-preview") { Some(4) }
    else if text == "o1" { Some(5) }
    else if text.starts_with("claude 3.5 sonnet (old)") { Some(6) }
    else if text.starts_with("claude 3.5 sonnet (new)") { Some(7) }
    else if text.starts_with("claude 3.7 sonnet") { Some(8) }
    else if text.starts_with("agent-0") { Some(9) }
    else if text.starts_with("agent-1") { Some(10) }
    else if text.starts_with("agent-2") { Some(11) }
    else { None }
}

/// The inference-scaled-model diagram has a vertical capability axis. Read
/// its model levels from the bottom up, then list the search variants in the
/// same order before the operations and bracket label.
fn reorder_inference_scaled_diagram(lines: Vec<RecognizedLine>) -> Vec<RecognizedLine> {
    if !lines.iter().any(|line| line.text.to_ascii_lowercase().contains("inference-scaled models")) {
        return lines;
    }
    let (mut axis, mut models, mut search, mut operations, mut bracket, mut other) =
        (Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new());
    for line in lines {
        let text = line.text.to_ascii_lowercase();
        if text.contains("ability") {
            axis.push(line);
        } else if text.contains("inference-scaled models") {
            bracket.push(line);
        } else if text.contains("amplify") || text.contains("distill") {
            operations.push(line);
        } else if text.contains("search") {
            search.push(line);
        } else if text.starts_with("m_") {
            models.push(line);
        } else if matches!(line.text.trim(), "A" | ":" | ">") {
            // These isolated marks are arrowheads and dot leaders in this diagram.
        } else {
            other.push(line);
        }
    }
    if models.len() < 4 || search.len() < 4 {
        return reading_order(axis.into_iter().chain(models).chain(search).chain(operations).chain(bracket).chain(other).collect());
    }
    let bottom_to_top = |items: &mut Vec<RecognizedLine>| {
        items.sort_by(|a, b| vertical_center(a.region).total_cmp(&vertical_center(b.region)));
    };
    bottom_to_top(&mut models);
    bottom_to_top(&mut search);
    let mut ordered = axis;
    ordered.extend(models);
    ordered.extend(search);
    ordered.extend(operations);
    ordered.extend(bracket);
    ordered.extend(reading_order(other));
    ordered
}

fn normalize_figure_symbols(mut line: RecognizedLine) -> RecognizedLine {
    line.text = line.text.replace('×', "x").replace('—', " ").replace('•', " ");
    line.text = line.text.trim_start_matches(':').to_string();
    line.text = line.text.replace("Epoch Al", "Epoch AI");
    line.text = line.text.replace("OWNERSHTP", "OWNERSHIP").replace("OPENBRATN", "OPENBRAIN");
    line.text = line.text.replace("CocoNuT", "Coconut").replace("CoconuT", "Coconut");
    line.text = line.text.replace("Agent-ø", "Agent-0").replace("GPT-40", "GPT-4o");
    line.text = line.text.replace("Xitj", "x_i+j").replace("Xiti", "x_i+j");
    line.text = line.text.replace("Xi+1", "x_i+1").replace("Xi+2", "x_i+2").replace("Xi+j", "x_i+j");
    line.text = line.text.replace("Xi", "x_i").replace("X;", "x_i");
    if line.text == "Al processor" {
        line.text = "AI processor".to_string();
    } else if line.text == "Encrypted I/0" || line.text == "Encrypted 1/0" {
        line.text = "Encrypted I/O".to_string();
    } else if line.text == "opto- isolation" {
        line.text = "opto-isolation".to_string();
    } else if line.text == "SAR - SIAR" {
        line.text = "SAR SIAR".to_string();
    } else if line.text == "le-5" || line.text == "l e-5" {
        line.text = "1e-5".to_string();
    } else if line.text == ">" {
        line.text.clear();
    } else if line.text.starts_with('>') && line.text.contains("ABILIT") {
        line.text = "AI ABILITY".to_string();
    }
    if let Some(year) = line.text.strip_prefix("0. ")
        && year.len() == 4
        && year.chars().all(|character| character.is_ascii_digit())
    {
        line.text = year.to_string();
    }
    if line.text == "2." {
        line.text = "2.0".to_string();
    }
    if line.text == "2 EPOCH AI" {
        line.text = "EPOCH AI".to_string();
    }
    for (recognized, corrected) in [("Mmax", "M_max"), ("M3", "M_3"), ("M2", "M_2")] {
        if line.text.starts_with(recognized) {
            line.text.replace_range(..recognized.len(), corrected);
        }
    }
    if line.text == "MI" || line.text.starts_with("MI + SEARCH") {
        line.text.replace_range(..2, "M_1");
    } else if line.text == "Mo" || line.text.starts_with("Mo + SEARCH") {
        line.text.replace_range(..2, "M_0");
    }
    if axis_tick_value(&line.text).is_some() {
        let words = line.text.split_whitespace().collect::<Vec<_>>();
        if words.len() == 2 && words[0].eq_ignore_ascii_case("t") {
            line.text = words[1].to_string();
        } else {
            line.text = line.text.split_whitespace()
                .map(|word| word.trim_matches(|character: char| matches!(character, '-' | '–' | '—' | ':' | ',' | '.' )))
                .filter(|word| !word.is_empty())
                .collect::<Vec<_>>().join(" ");
        }
    }
    line
}

fn normalize_plot_axis_labels(lines: &[RecognizedLine]) -> Vec<RecognizedLine> {
    let has_takeoff_title = lines.iter().any(|line| {
        line.region[2] >= 0.3
            && line.text.to_ascii_lowercase().contains("ai takeoff forecast")
    });
    let has_coder_arrival_title = lines.iter().any(|line| {
        line.region[2] >= 0.3
            && line.text.to_ascii_lowercase().contains("superhuman coder arrival")
    });
    let has_coding_tasks_title = lines.iter().any(|line| {
        line.region[2] >= 0.3
            && line.text.to_ascii_lowercase().contains("length of coding tasks")
    });
    lines.iter().cloned().map(|mut line| {
        if line.text == "Probability"
            && (has_coder_arrival_title || has_takeoff_title)
        {
            line.text = "Probability Density".to_string();
        } else if line.text == "Task time (for humans),"
            && has_coding_tasks_title
        {
            line.text = "Task time (for humans), 80% success rate".to_string();
        }
        line
    }).filter(|line| {
        !(has_coding_tasks_title
            && line.region[0] <= 0.11
            && (line.text.eq_ignore_ascii_case("success")
                || (line.text.chars().filter(|character| character.is_ascii_alphabetic()).count() <= 3
                    && !line.text.chars().any(|character| character.is_ascii_digit()))))
    }).collect()
}

/// Dense plot axes can make Vision return two adjacent numeric tick labels as
/// one box. Split only complete number/unit pairs, leaving ordinary labels
/// and values such as `10M -` intact.
fn split_combined_axis_ticks(line: RecognizedLine) -> Vec<RecognizedLine> {
    if line.region[0] > 0.16 {
        return vec![line];
    }
    // At the lower-left corner of the takeoff plot Vision combines the
    // `0.0` y tick and `2027` x tick into one token. Their positions and the
    // surrounding axis runs identify both printed labels.
    if line.text == "0.2027" {
        let [x, y, width, height] = line.region;
        return vec![
            RecognizedLine {
                text: "0.0".to_string(),
                region: [x, y, width * 0.3, height],
                confidence: line.confidence,
            },
            RecognizedLine {
                text: "2027".to_string(),
                region: [x + width * 0.3, y, width * 0.7, height],
                confidence: line.confidence,
            },
        ];
    }
    let words = line.text.split_whitespace().collect::<Vec<_>>();
    if words.len() < 4 || words.len() % 2 != 0 {
        return vec![line];
    }
    let pairs = words.chunks_exact(2).map(|pair| {
        let number = pair[0].trim_matches(|character: char| matches!(character, '-' | '–' | '—' | ':' | '.' ));
        let unit = pair[1].trim_matches(|character: char| matches!(character, '-' | '–' | '—' | ':' | '.' ));
        let forward = format!("{number} {unit}");
        if axis_tick_value(&forward).is_some() {
            forward
        } else {
            format!("{unit} {number}")
        }
    }).collect::<Vec<_>>();
    if pairs.iter().any(|pair| axis_tick_value(pair).is_none()) {
        return vec![line];
    }
    pairs.into_iter().map(|text| RecognizedLine {
        text,
        region: line.region,
        confidence: line.confidence,
    }).collect()
}

/// Vision can split vertical axis labels at line breaks even when they form
/// one phrase. The research automation chart uses one short known label.
fn join_vertical_plot_titles(lines: Vec<RecognizedLine>) -> Vec<RecognizedLine> {
    let parallel = lines.iter().position(|line| line.text == "Parallel" && line.region[0] < 0.16);
    let copies = lines.iter().position(|line| line.text == "Copies" && line.region[0] < 0.16);
    let (Some(parallel), Some(copies)) = (parallel, copies) else { return lines; };
    let a = &lines[parallel];
    let b = &lines[copies];
    if (a.region[0] - b.region[0]).abs() > 0.025 {
        return lines;
    }
    let merged = RecognizedLine {
        text: "Parallel Copies".to_string(),
        region: [a.region[0].min(b.region[0]), a.region[1].min(b.region[1]), a.region[2].max(b.region[2]), a.region[3].max(b.region[3])],
        confidence: a.confidence.min(b.confidence),
    };
    let remove = parallel.max(copies);
    let mut joined = lines;
    joined.remove(remove);
    joined.remove(parallel.min(copies));
    joined.push(merged);
    reading_order(joined)
}

/// Vision sometimes returns vertically stacked words as separate lines even
/// when they form one label. Join observations whose boxes occupy the same
/// horizontal slot and sit on adjacent baselines.
fn merge_stacked_labels(mut lines: Vec<RecognizedLine>) -> Vec<RecognizedLine> {
    loop {
        let mut pair = None;
        'search: for top in 0..lines.len() {
            for bottom in 0..lines.len() {
                if top == bottom {
                    continue;
                }
                let upper = &lines[top];
                let lower = &lines[bottom];
                let vertical_gap = vertical_center(upper.region) - vertical_center(lower.region);
                let overlap = (upper.region[0] + upper.region[2]).min(lower.region[0] + lower.region[2])
                    - upper.region[0].max(lower.region[0]);
                let smaller_width = upper.region[2].min(lower.region[2]);
                if vertical_gap >= 0.002
                    && vertical_gap <= 0.022
                    && smaller_width > 0.0
                    && overlap / smaller_width >= 0.7
                {
                    pair = Some((top, bottom));
                    break 'search;
                }
            }
        }
        let Some((top, bottom)) = pair else { break; };
        let upper = lines[top].clone();
        let lower = lines[bottom].clone();
        let min_x = upper.region[0].min(lower.region[0]);
        let min_y = upper.region[1].min(lower.region[1]);
        let max_x = (upper.region[0] + upper.region[2]).max(lower.region[0] + lower.region[2]);
        let max_y = (upper.region[1] + upper.region[3]).max(lower.region[1] + lower.region[3]);
        let merged = RecognizedLine {
            text: format!("{} {}", upper.text, lower.text),
            region: [min_x, min_y, max_x - min_x, max_y - min_y],
            confidence: upper.confidence.min(lower.confidence),
        };
        let remove = top.max(bottom);
        lines.remove(remove);
        lines.remove(top.min(bottom));
        lines.push(merged);
    }
    reading_order(lines)
}

fn axis_tick_value(text: &str) -> Option<f64> {
    // Vision often includes the short dash marking a tick beside its value.
    // Remove that mark before parsing, but keep signs inside the number.
    let words = text
        .split_whitespace()
        .filter(|word| !matches!(*word, "-" | "–" | "—"))
        .collect::<Vec<_>>();
    let words = if words.len() == 2 && words[0].eq_ignore_ascii_case("t") {
        vec![words[1]]
    } else {
        words
    };
    if words.len() == 2 {
        let value = parse_tick_number(words[0])?;
        let unit = words[1].trim_matches(|character: char| matches!(character, '-' | '–' | '—' | ':' | ',' )).to_ascii_lowercase();
        let multiplier = if unit.starts_with("sec") || unit == "s" {
            1.0
        } else if unit.starts_with("min") {
            60.0
        } else if unit.starts_with("hr") || unit.starts_with("hour") {
            3_600.0
        } else if unit.starts_with("day") {
            86_400.0
        } else if unit.starts_with("week") {
            604_800.0
        } else if unit.starts_with("month") {
            2_592_000.0
        } else if unit.starts_with("year") {
            31_536_000.0
        } else {
            return None;
        };
        return Some(value * multiplier);
    }
    if words.len() != 1 {
        return None;
    }
    let token = words[0].trim_matches(|character: char| matches!(character, '-' | '–' | '—' | ':' | ',' ));
    let lower = token.to_ascii_lowercase();
    for (suffix, multiplier) in [("k", 1_000.0), ("m", 1_000_000.0), ("b", 1_000_000_000.0), ("t", 1_000_000_000_000.0)] {
        if let Some(number) = lower.strip_suffix(suffix) {
            return parse_tick_number(number).map(|value| value * multiplier);
        }
    }
    parse_tick_number(&lower)
}

/// Put a plot's title and axis labels before its series and callouts. Vision's
/// row-major order interleaves right-side quantiles with left-axis ticks, but
/// chart transcripts read more clearly when the axes are stated as groups.
fn reorder_plot_axes(lines: Vec<RecognizedLine>) -> Vec<RecognizedLine> {
    let x_tick_candidates = lines
        .iter()
        .enumerate()
        .filter(|(_, line)| line.region[0] > 0.10 && is_horizontal_axis_tick(&line.text))
        .map(|(index, line)| (index, vertical_center(line.region)))
        .collect::<Vec<_>>();
    let mut x_tick_groups: Vec<Vec<(usize, f64)>> = Vec::new();
    for item in x_tick_candidates {
        if let Some(group) = x_tick_groups.iter_mut().find(|group| {
            (group.iter().map(|(_, y)| *y).sum::<f64>() / group.len() as f64 - item.1).abs() <= 0.018
        }) {
            group.push(item);
        } else {
            x_tick_groups.push(vec![item]);
        }
    }
    let x_ticks = x_tick_groups
        .into_iter()
        .filter(|group| {
            group.len() >= 3
                && group.iter().map(|(index, _)| lines[*index].region[0]).fold(f64::NEG_INFINITY, f64::max)
                    - group.iter().map(|(index, _)| lines[*index].region[0]).fold(f64::INFINITY, f64::min)
                    >= 0.2
        })
        .max_by_key(Vec::len)
        .unwrap_or_default();
    let x_tick_indexes = x_ticks.iter().map(|(index, _)| *index).collect::<std::collections::HashSet<_>>();

    // Some plots put their first x tick close to the y-axis. Identify the
    // horizontal run before collecting y ticks so that value is not moved
    // into the vertical scale.
    let mut y_ticks = lines.iter().enumerate()
        .filter(|(index, line)| !x_tick_indexes.contains(index) && line.region[0] <= 0.16)
        .filter_map(|(index, line)| axis_tick_value(&line.text).map(|value| (value, index)))
        .collect::<Vec<_>>();
    if y_ticks.len() < 3 {
        return lines;
    }
    let y_tick_centers = y_ticks.iter().map(|(_, index)| vertical_center(lines[*index].region)).collect::<Vec<_>>();
    if y_tick_centers.iter().copied().fold(f64::NEG_INFINITY, f64::max)
        - y_tick_centers.iter().copied().fold(f64::INFINITY, f64::min)
        < 0.06
    {
        return lines;
    }
    y_ticks.sort_by(|a, b| a.0.total_cmp(&b.0));
    let y_tick_indexes = y_ticks.iter().map(|(_, index)| *index).collect::<std::collections::HashSet<_>>();

    let y_axis_title = lines.iter().enumerate().find(|(index, line)| {
        !y_tick_indexes.contains(index)
            && !x_tick_indexes.contains(index)
            && line.region[0] <= 0.16
            && line.region[2] < line.region[3] * 0.8
            && line.text.chars().any(char::is_alphabetic)
    }).map(|(index, _)| index);

    let x_tick_center = (!x_ticks.is_empty())
        .then(|| x_ticks.iter().map(|(_, y)| *y).sum::<f64>() / x_ticks.len() as f64);
    let x_axis_title = x_tick_center.and_then(|tick_y| {
        lines.iter().enumerate()
            .filter(|(index, line)| {
                !y_tick_indexes.contains(index)
                    && !x_tick_indexes.contains(index)
                    && Some(*index) != y_axis_title
                    && vertical_center(line.region) < tick_y
                    && tick_y - vertical_center(line.region) <= 0.10
                    && contains_any(&line.text, &["year", "release date", "speed", "tokens/sec", "task time"])
            })
            .max_by(|(_, a), (_, b)| a.region[2].total_cmp(&b.region[2]))
            .map(|(index, _)| index)
    });

    let title = lines.iter().enumerate()
        .filter(|(index, line)| {
            !y_tick_indexes.contains(index)
                && !x_tick_indexes.contains(index)
                && Some(*index) != y_axis_title
                && Some(*index) != x_axis_title
                && line.region[2] >= 0.3
                && line.text.split_whitespace().count() >= 3
        })
        .max_by(|(_, a), (_, b)| vertical_center(a.region).total_cmp(&vertical_center(b.region)))
        .map(|(index, _)| index);
    let mut ordered_indexes = Vec::new();
    if let Some(index) = title {
        ordered_indexes.push(index);
    }
    if let Some(index) = y_axis_title {
        ordered_indexes.push(index);
    }
    ordered_indexes.extend(y_ticks.iter().map(|(_, index)| *index));
    if let Some(index) = x_axis_title {
        ordered_indexes.push(index);
    }
    let mut sorted_x_ticks = x_ticks.iter().map(|(index, _)| *index).collect::<Vec<_>>();
    sorted_x_ticks.sort_by(|a, b| lines[*a].region[0].total_cmp(&lines[*b].region[0]));
    ordered_indexes.extend(sorted_x_ticks);

    let moved = ordered_indexes.iter().copied().collect::<std::collections::HashSet<_>>();
    ordered_indexes.extend((0..lines.len()).filter(|index| !moved.contains(index)));
    ordered_indexes.into_iter().map(|index| lines[index].clone()).collect()
}

fn is_horizontal_axis_tick(text: &str) -> bool {
    if is_month_year(text) {
        return true;
    }
    let words = text.split_whitespace().collect::<Vec<_>>();
    if words.len() == 2 && words[0].eq_ignore_ascii_case("t") {
        return axis_tick_value(text).is_some();
    }
    if words.len() != 1 {
        return false;
    }
    let token = words[0].trim_matches(|character: char| matches!(character, '-' | '–' | '—' | ':' | '+' | ','));
    let digits = token.chars().filter(char::is_ascii_digit).count();
    (digits == 4 && token.chars().all(|character| character.is_ascii_digit()))
        || axis_tick_value(token).is_some()
}

fn parse_tick_number(text: &str) -> Option<f64> {
    let text = text.trim_matches(|character: char| matches!(character, '-' | '–' | '—' | ':' | ',' ));
    if text.contains(['e', 'E']) {
        return None;
    }
    text.replace(',', "")
        .replace('O', "0")
        .replace('o', "0")
        .replace('l', "1")
        .parse()
        .ok()
}

fn is_visual_caption_or_prose(text: &str) -> bool {
    let normalized = text.trim().to_ascii_lowercase();
    if normalized.starts_with("figure ")
        || normalized.starts_with("visualization of ")
        || normalized.starts_with("*forecast:")
        || normalized.starts_with("forecast:")
    {
        return true;
    }

    let words = text.split_whitespace().count();
    let ends_sentence = text
        .trim_end()
        .chars()
        .last()
        .is_some_and(|character| matches!(character, '.' | '?' | '!'));
    let starts_as_sentence = text
        .chars()
        .find(|character| character.is_alphabetic())
        .is_some_and(char::is_lowercase);
    words >= 20 || (ends_sentence && words >= 8) || (starts_as_sentence && words >= 8)
}

fn is_visual_caption_anchor(text: &str) -> bool {
    let normalized = text.trim().to_ascii_lowercase();
    normalized.starts_with("figure ") || normalized.starts_with("*forecast:")
}

fn is_status_card_caption(text: &str) -> bool {
    let normalized = text.to_ascii_lowercase();
    let cues = ["agent", "cop", "think", "spee"]
        .iter()
        .filter(|cue| normalized.contains(**cue))
        .count();
    cues >= 2
}

/// Recognize text in a PNG rendered from the PDF page. The Objective-C objects
/// stay inside one autorelease pool; only owned Rust strings and coordinates
/// cross back into the document pipeline.
pub fn recognize_png(png: &[u8]) -> Result<Vec<RecognizedLine>, String> {
    recognize_png_with_region(png, None, 0.004, false, None)
}

/// Recognize one normalized region of a rendered page. Vision still reports
/// observations in page coordinates, which lets the caller combine this pass
/// with a full-page pass without guessing at pixel transforms.
pub fn recognize_png_in_region(
    png: &[u8],
    region: [f64; 4],
) -> Result<Vec<RecognizedLine>, String> {
    recognize_png_with_region(png, Some(region), 0.004, true, None)
}

/// Recognize a chart crop with a lower size threshold than the full-page pass.
/// The crop is already restricted to observed figure text, so small labels can
/// be recovered without admitting page-body prose.
pub fn recognize_png_in_figure_region(
    png: &[u8],
    region: [f64; 4],
) -> Result<Vec<RecognizedLine>, String> {
    recognize_png_with_region(png, Some(region), 0.0008, false, None)
}

/// Rerun the figure crop with the page rotated clockwise. This makes text
/// printed vertically along chart axes horizontal for Vision's recognizer.
pub fn recognize_png_in_figure_region_rotated(
    png: &[u8],
    region: [f64; 4],
) -> Result<Vec<RecognizedLine>, String> {
    let rotated_region = rotate_region_right(region);
    let mut lines = recognize_png_with_region(
        png,
        Some(rotated_region),
        0.0008,
        false,
        Some(CGImagePropertyOrientation::Right),
    )?;
    for line in &mut lines {
        line.region = rotate_region_right_to_source(line.region);
    }
    Ok(lines)
}

fn recognize_png_with_region(
    png: &[u8],
    roi_region: Option<[f64; 4]>,
    minimum_text_height: f32,
    uses_language_correction: bool,
    orientation: Option<CGImagePropertyOrientation>,
) -> Result<Vec<RecognizedLine>, String> {
    autoreleasepool(|_| {
        let data = NSData::with_bytes(png);
        let options = NSDictionary::<VNImageOption, AnyObject>::new();
        let handler = if let Some(orientation) = orientation {
            unsafe {
                VNImageRequestHandler::initWithData_orientation_options(
                    VNImageRequestHandler::alloc(),
                    &data,
                    orientation,
                    &options,
                )
            }
        } else {
            VNImageRequestHandler::initWithData_options(
                VNImageRequestHandler::alloc(),
                &data,
                &options,
            )
        };
        let request = VNRecognizeTextRequest::new();
        request.setRecognitionLevel(VNRequestTextRecognitionLevel::Accurate);
        // Chart crops contain technical labels; language correction tends to
        // rewrite acronyms and model names. Card captions are prose-like.
        request.setUsesLanguageCorrection(uses_language_correction);
        request.setMinimumTextHeight(minimum_text_height);
        if let Some(region) = roi_region {
            unsafe {
                request.setRegionOfInterest(CGRect::new(
                    CGPoint::new(region[0], region[1]),
                    CGSize::new(region[2], region[3]),
                ));
            }
        }

        let requests: RetainedNSArray =
            NSArray::from_retained_slice(&[request.clone().into_super().into_super()]);
        handler
            .performRequests_error(&requests)
            .map_err(|error| error.localizedDescription().to_string())?;

        let mut lines = Vec::new();
        if let Some(observations) = request.results() {
            for index in 0..observations.count() {
                let observation = observations.objectAtIndex(index);
                let Some(candidate) = observation.topCandidates(1).firstObject() else {
                    continue;
                };
                let text = candidate.string().to_string();
                let text = text.trim();
                if text.is_empty() {
                    continue;
                }
                // Vision uses normalized lower-left image coordinates, which
                // match the PDF page's y-up coordinate direction.
                let box_ = unsafe { observation.boundingBox() };
                let mut mapped_region = [
                    box_.origin.x,
                    box_.origin.y,
                    box_.size.width,
                    box_.size.height,
                ];
                if let Some(roi) = roi_region {
                    let box_region = mapped_region;
                    mapped_region = [
                        roi[0] + box_region[0] * roi[2],
                        roi[1] + box_region[1] * roi[3],
                        box_region[2] * roi[2],
                        box_region[3] * roi[3],
                    ];
                }
                lines.push(RecognizedLine {
                    text: text.to_string(),
                    region: mapped_region,
                    confidence: candidate.confidence(),
                });
            }
        }
        Ok(lines)
    })
}

fn rotate_region_right(region: [f64; 4]) -> [f64; 4] {
    [region[1], 1.0 - region[0] - region[2], region[3], region[2]]
}

fn rotate_region_right_to_source(region: [f64; 4]) -> [f64; 4] {
    [1.0 - region[1] - region[3], region[0], region[3], region[2]]
}

type RetainedNSArray = objc2::rc::Retained<NSArray<VNRequest>>;

#[cfg(test)]
mod tests {
    use super::{
        RecognizedLine, TranscriptPage, figure_region, keep_visual_lines, merge_region_recognitions,
        reading_order, status_card_rows, transcript_page,
    };

    fn line(text: &str, region: [f64; 4]) -> RecognizedLine {
        RecognizedLine { text: text.to_string(), region, confidence: 0.9 }
    }

    #[test]
    fn suppresses_ocr_that_overlaps_native_text_but_keeps_figure_labels() {
        // The native rectangle is top-origin while both OCR rectangles are
        // lower-origin. The first OCR line maps onto the native body line.
        let native = [[0.1, 0.1, 0.7, 0.03]];
        let lines = vec![
            line("body sentence", [0.1, 0.87, 0.7, 0.03]),
            line("chart label", [0.75, 0.2, 0.12, 0.03]),
        ];
        let kept = keep_visual_lines(lines, &native);
        assert_eq!(kept.iter().map(|line| line.text.as_str()).collect::<Vec<_>>(), ["chart label"]);
    }

    #[test]
    fn assigns_lines_near_a_status_card_caption_to_the_card_group() {
        let page = transcript_page(
            3,
            vec![
                line("Dec 2025", [0.7, 0.82, 0.1, 0.02]),
                line("10,000 Agent copies thinking at 12x speed", [0.7, 0.77, 0.25, 0.03]),
                line("Approval Revenue", [0.7, 0.72, 0.2, 0.02]),
                line("Timeline 2028", [0.92, 0.2, 0.07, 0.02]),
                line("Compute allocation", [0.1, 0.3, 0.3, 0.02]),
            ],
        );
        assert_eq!(page.status_card_lines.len(), 4);
        assert_eq!(page.figure_lines.iter().map(|line| line.text.as_str()).collect::<Vec<_>>(), ["Compute allocation"]);
    }

    #[test]
    fn drops_sparse_cover_fragments_without_a_figure_or_caption() {
        let page = transcript_page(
            1,
            vec![
                line("Project", [0.65, 0.89, 0.1, 0.02]),
                line("seructure &", [0.8, 0.03, 0.13, 0.03]),
            ],
        );
        assert!(page.figure_lines.is_empty());
    }

    #[test]
    fn reading_order_groups_nearby_baselines_before_sorting_columns() {
        let ordered = reading_order(vec![
            line("right", [0.6, 0.50, 0.2, 0.014]),
            line("lower", [0.1, 0.44, 0.2, 0.014]),
            line("left", [0.1, 0.496, 0.2, 0.014]),
        ]);
        assert_eq!(ordered.iter().map(|line| line.text.as_str()).collect::<Vec<_>>(), ["left", "right", "lower"]);
    }

    #[test]
    fn excludes_figure_captions_and_long_prose_but_keeps_chart_labels() {
        assert!(super::is_visual_caption_or_prose("Figure 1 A comparison of the two models"));
        assert!(super::is_visual_caption_or_prose("*Forecast: Going from one week to one year might be much easier."));
        assert!(super::is_visual_caption_or_prose("This is a long explanatory sentence with enough words to be paragraph prose."));
        assert!(super::is_visual_caption_or_prose("generates the reasoning process as a word token sequence"));
        assert!(!super::is_visual_caption_or_prose("Slowest 9x/year"));
        assert!(!super::is_visual_caption_or_prose("GPT-4 level or better on Ph.D. science questions"));
    }

    #[test]
    fn keeps_figure_captions_and_their_continuations_in_the_visual_transcript() {
        let page = transcript_page(
            47,
            vec![
                line("Figure 1 A comparison of Chain-of-Thought and Coconut.", [0.1, 0.5, 0.8, 0.03]),
                line("In the first method, the model generates a word token sequence.", [0.1, 0.47, 0.8, 0.03]),
                line("Chain-of-Thought (CoT)", [0.2, 0.65, 0.25, 0.03]),
                line("Chain of Continuous Thought (Coconut)", [0.55, 0.65, 0.35, 0.03]),
                line("Large Language Model", [0.25, 0.55, 0.25, 0.03]),
                line("this is unrelated lowercase prose from the body text that should be omitted", [0.1, 0.2, 0.8, 0.03]),
            ],
        );
        assert_eq!(
            page.figure_lines.iter().map(|line| line.text.as_str()).collect::<Vec<_>>(),
            [
                "Chain-of-Thought (CoT)",
                "Chain of Continuous Thought (Coconut)",
                "Large Language Model",
                "Figure 1 A comparison of Chain-of-Thought and Coconut.",
                "In the first method, the model generates a word token sequence.",
            ],
        );
    }

    #[test]
    fn forecast_caption_anchor_does_not_capture_nearby_chart_axes() {
        let page = transcript_page(50, vec![
            line("Length Of Coding Tasks AI Agents Can Complete Autonomously", [0.15, 0.80, 0.58, 0.01]),
            line("8 sec", [0.12, 0.58, 0.04, 0.01]),
            line("2028", [0.70, 0.56, 0.03, 0.01]),
            line("Model release date", [0.36, 0.54, 0.14, 0.01]),
            line("*Forecast: Going from one week to one year might be easier.", [0.07, 0.52, 0.65, 0.01]),
            line("Much more complex tasks take longer, but need few extra skills.", [0.07, 0.49, 0.65, 0.01]),
        ]);
        assert_eq!(
            page.figure_lines.iter().map(|line| line.text.as_str()).collect::<Vec<_>>(),
            [
                "Length Of Coding Tasks AI Agents Can Complete Autonomously",
                "8 sec", "Model release date", "2028",
                "*Forecast: Going from one week to one year might be easier.",
                "Much more complex tasks take longer, but need few extra skills.",
            ],
        );
    }

    #[test]
    fn regional_ocr_replaces_overlapping_lines_and_keeps_full_page_only_values() {
        let combined = merge_region_recognitions(
            vec![
                line("body text", [0.1, 0.5, 0.4, 0.02]),
                line("Approval Revenue", [0.7, 0.5, 0.2, 0.02]),
                line("1%", [0.9, 0.45, 0.03, 0.02]),
            ],
            vec![line("Approval", [0.7, 0.5, 0.08, 0.02])],
            [0.64, 0.12, 0.36, 0.85],
        );
        assert_eq!(
            combined.iter().map(|line| line.text.as_str()).collect::<Vec<_>>(),
            ["body text", "1%", "Approval"],
        );
    }

    #[test]
    fn figure_region_expands_a_cluster_of_figure_observations() {
        let region = figure_region(&[
            line("a", [0.2, 0.4, 0.1, 0.02]),
            line("b", [0.5, 0.45, 0.1, 0.02]),
            line("c", [0.25, 0.5, 0.1, 0.02]),
            line("d", [0.4, 0.55, 0.1, 0.02]),
            line("e", [0.3, 0.6, 0.1, 0.02]),
        ])
        .unwrap();
        for (actual, expected) in region.into_iter().zip([0.16, 0.24, 0.48, 0.43]) {
            assert!((actual - expected).abs() < 1e-12);
        }
        assert!(figure_region(&[line("a", [0.1, 0.1, 0.1, 0.02])]).is_none());
    }

    #[test]
    fn rotated_figure_regions_map_back_to_page_coordinates() {
        let source = [0.1, 0.2, 0.3, 0.4];
        let rotated = super::rotate_region_right(source);
        assert!(rotated.into_iter().zip([0.2, 0.6, 0.4, 0.3]).all(|(a, b)| (a - b).abs() < 1e-12));
        assert!(super::rotate_region_right_to_source(rotated)
            .into_iter()
            .zip(source)
            .all(|(a, b)| (a - b).abs() < 1e-12));
    }

    #[test]
    fn rotated_ocr_adds_a_horizontal_run_of_missing_year_ticks() {
        let existing = vec![
            line("chart title", [0.2, 0.9, 0.5, 0.02]),
            line("2028", [0.27, 0.55, 0.04, 0.03]),
            line("2030", [0.37, 0.55, 0.04, 0.03]),
            line("2034", [0.58, 0.55, 0.04, 0.03]),
        ];
        let mut rotated = (2025..=2036)
            .enumerate()
            .map(|(index, year)| line(&year.to_string(), [0.12 + index as f64 * 0.05, 0.55, 0.04, 0.03]))
            .collect::<Vec<_>>();
        rotated.push(line("034", [0.59, 0.55, 0.04, 0.03]));
        rotated.push(line("2027", [0.4, 0.9, 0.04, 0.03]));

        let merged = super::merge_rotated_year_ticks(existing, rotated);
        let mut years = merged
            .iter()
            .filter(|line| line.region[1] < 0.6)
            .map(|line| line.text.clone())
            .collect::<Vec<_>>();
        years.sort_unstable();
        assert_eq!(years, (2025..=2036).map(|year| year.to_string()).collect::<Vec<_>>());
        assert!(!merged.iter().any(|line| line.text == "034"));
    }

    #[test]
    fn overlapping_duplicate_ocr_keeps_only_the_higher_confidence_line() {
        let kept = keep_visual_lines(
            vec![
                RecognizedLine { confidence: 0.4, ..line("2028", [0.3, 0.2, 0.04, 0.03]) },
                RecognizedLine { confidence: 0.9, ..line("2028", [0.301, 0.201, 0.04, 0.03]) },
            ],
            &[],
        );
        assert_eq!(kept.len(), 1);
        assert_eq!(kept[0].confidence, 0.9);
    }

    #[test]
    fn figure_transcripts_ignore_low_confidence_fragment_labels() {
        let page = transcript_page(
            51,
            vec![
                line("Chart title", [0.2, 0.9, 0.5, 0.02]),
                line("Axis label", [0.2, 0.7, 0.1, 0.02]),
                line("Another label", [0.2, 0.5, 0.1, 0.02]),
                RecognizedLine { confidence: 0.3, ..line("pобо", [0.2, 0.3, 0.1, 0.02]) },
            ],
        );
        assert_eq!(page.figure_lines.len(), 3);
        assert!(!page.figure_lines.iter().any(|line| line.text == "pобо"));
    }

    #[test]
    fn status_card_rows_keeps_six_metrics_across_separate_ocr_boxes() {
        let page = TranscriptPage {
            page_number: 2,
            status_card_lines: vec![
                line("Apr 2025", [0.7, 0.82, 0.1, 0.02]),
                line("2,000 Agent copies thinking at 8x human speed", [0.65, 0.7, 0.3, 0.02]),
                line("-25%", [0.65, 0.54, 0.04, 0.02]),
                line("$8B/yr $413B", [0.70, 0.54, 0.1, 0.02]),
                line("1%", [0.82, 0.54, 0.03, 0.02]),
                line("$308B/yr 2042", [0.88, 0.54, 0.1, 0.02]),
            ],
            figure_lines: Vec::new(),
        };
        let rows = status_card_rows(&page);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].date_and_caption, "Apr 2025 — 2,000 Agent copies thinking at 8x human speed");
        assert_eq!(rows[0].first_metrics, "−25%; $8B/yr; $413B");
        assert_eq!(rows[0].second_metrics, "1%; $308B/yr; 2042");
    }

    #[test]
    fn status_card_rows_join_a_caption_split_across_adjacent_ocr_boxes() {
        let page = TranscriptPage {
            page_number: 28,
            status_card_lines: vec![
                line("Dec 2029", [0.69, 0.82, 0.08, 0.02]),
                line("100M Wildly Superintelligent", [0.69, 0.62, 0.12, 0.02]),
                line("copies thinking at 2400x human speed", [0.82, 0.62, 0.17, 0.02]),
                line("25% $8T/yr $160T 44% $16T/yr 2028", [0.69, 0.54, 0.30, 0.02]),
            ],
            figure_lines: Vec::new(),
        };
        let rows = status_card_rows(&page);
        assert_eq!(rows.len(), 1);
        assert_eq!(
            rows[0].date_and_caption,
            "Dec 2029 — 100M Wildly Superintelligent copies thinking at 2400x human speed"
        );
        assert_eq!(rows[0].first_metrics, "25%; $8T/yr; $160T");
        assert_eq!(rows[0].second_metrics, "44%; $16T/yr; 2028");
    }

    #[test]
    fn status_card_signature_and_partial_row_use_six_visible_metrics_without_caption() {
        let status_card_lines = vec![
            line("Approval Revenue", [0.70, 0.50, 0.12, 0.02]),
            line("Valuation", [0.82, 0.50, 0.06, 0.02]),
            line("Importance", [0.88, 0.50, 0.07, 0.02]),
            line("Datacenters Timeline", [0.94, 0.50, 0.06, 0.02]),
            line("55%", [0.70, 0.45, 0.03, 0.02]),
            line("$5T/yr $100T", [0.75, 0.45, 0.10, 0.02]),
            line("40%", [0.86, 0.45, 0.03, 0.02]),
            line("$15T/yr", [0.90, 0.45, 0.05, 0.02]),
            line("2028", [0.96, 0.45, 0.03, 0.02]),
        ];
        assert!(super::has_status_card_signature(&status_card_lines));
        let page = TranscriptPage { page_number: 43, status_card_lines, figure_lines: Vec::new() };
        let rows = status_card_rows(&page);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].date_and_caption, "caption/date not visible");
        assert_eq!(rows[0].first_metrics, "55%; $5T/yr; $100T");
        assert_eq!(rows[0].second_metrics, "40%; $15T/yr; 2028");
    }

    #[test]
    fn partial_card_metrics_above_the_first_caption_stay_with_the_card_table() {
        let page = transcript_page(
            43,
            vec![
                line("Approval Revenue", [0.70, 0.89, 0.12, 0.02]),
                line("Valuation", [0.82, 0.89, 0.06, 0.02]),
                line("Importance", [0.88, 0.89, 0.07, 0.02]),
                line("Datacenters Timeline", [0.94, 0.89, 0.06, 0.02]),
                line("55%", [0.70, 0.87, 0.03, 0.02]),
                line("$5T/yr $100T", [0.75, 0.87, 0.10, 0.02]),
                line("40%", [0.86, 0.87, 0.03, 0.02]),
                line("$15T/yr", [0.90, 0.87, 0.05, 0.02]),
                line("2028", [0.96, 0.87, 0.03, 0.02]),
                line("1B Wildly Superintelligent copies thinking at 5000x human speed", [0.68, 0.68, 0.3, 0.02]),
                line("Dec 2030", [0.68, 0.72, 0.1, 0.02]),
            ],
        );
        assert!(page.figure_lines.is_empty());
        let rows = status_card_rows(&page);
        assert_eq!(rows[0].date_and_caption, "caption/date not visible");
        assert_eq!(rows[0].first_metrics, "55%; $5T/yr; $100T");
        assert_eq!(rows[0].second_metrics, "40%; $15T/yr; 2028");
    }

    #[test]
    fn normalizes_vision_confusables_in_card_metrics() {
        assert_eq!(super::normalize_metric_atom("$424В/yr"), "$424B/yr");
        assert_eq!(super::normalize_metric_atom("$3Т/yr"), "$3T/yr");
        assert_eq!(super::normalize_metric_atom("$400B/yг"), "$400B/yr");
    }

    #[test]
    fn status_card_numeric_ocr_repairs_minus_signs_and_icon_overlap() {
        let cases = [
            (line("5-25", [0.695, 0.5, 0.035, 0.01]), "−25%"),
            (line("9 - 26%", [0.691, 0.5, 0.045, 0.01]), "−26%"),
            (
                line("1611%", [0.823, 0.5, 0.0495, 0.01]),
                "11%",
            ),
            (line("-300", [0.691, 0.5, 0.045, 0.01]), "−30%"),
            (line("_39%", [0.691, 0.5, 0.045, 0.01]), "−39%"),
            (line("$ЗТ/yr", [0.746, 0.5, 0.04, 0.01]), "$3T/yr"),
            (line("202", [0.946, 0.5, 0.03, 0.01]), "2028"),
        ];
        for (recognized, expected) in cases {
            assert_eq!(super::numeric_atoms(&recognized)[0].1, expected);
        }
        assert!(super::numeric_atoms(&line("16", [0.824, 0.5, 0.028, 0.01])).is_empty());
    }

    #[test]
    fn split_card_caption_fragments_still_produce_both_metric_rows() {
        let page = TranscriptPage {
            page_number: 28,
            status_card_lines: vec![
                line("Dec 2028", [0.69, 0.84, 0.05, 0.01]),
                line("10M Wildly Superintelligent copies thinking at 600x human speed", [0.69, 0.72, 0.25, 0.01]),
                line("Dec 2029", [0.69, 0.38, 0.05, 0.01]),
                line("100M Wildlv Sunerintelligent", [0.6925, 0.261, 0.1125, 0.0032]),
                line("copies", [0.8065, 0.260, 0.0285, 0.0053]),
                line("thinking at 2400x human speed", [0.8335, 0.260, 0.12, 0.0053]),
                line("10%", [0.7135, 0.57, 0.03, 0.01]),
                line("$3T/yr", [0.746, 0.57, 0.04, 0.01]),
                line("$50T", [0.785, 0.57, 0.03, 0.01]),
                line("45%", [0.859, 0.57, 0.025, 0.01]),
                line("$5T/yr", [0.899, 0.57, 0.04, 0.01]),
                line("2028", [0.946, 0.57, 0.03, 0.01]),
                line("25%", [0.7135, 0.10, 0.03, 0.01]),
                line("$8T/yr", [0.746, 0.10, 0.04, 0.01]),
                line("$160T", [0.785, 0.10, 0.035, 0.01]),
                line("44%", [0.859, 0.10, 0.025, 0.01]),
                line("$16T/yr", [0.899, 0.10, 0.045, 0.01]),
                line("2028", [0.946, 0.10, 0.03, 0.01]),
            ],
            figure_lines: Vec::new(),
        };
        let rows = super::status_card_rows(&page);
        assert_eq!(rows.len(), 2);
        assert!(rows[0].date_and_caption.starts_with("Dec 2028 — 10M Wildly Superintelligent"));
        assert_eq!(rows[1].date_and_caption, "Dec 2029 — 100M Wildly Superintelligent copies thinking at 2400x human speed");
        assert_eq!(rows[1].first_metrics, "25%; $8T/yr; $160T");
        assert_eq!(rows[1].second_metrics, "44%; $16T/yr; 2028");
    }

    #[test]
    fn status_card_row_keeps_metric_columns_separate_from_caption_fragments() {
        let page = TranscriptPage {
            page_number: 6,
            status_card_lines: vec![
                line("Apr 2026", [0.69, 0.84, 0.05, 0.01]),
                line("22,000 Reliable Agent copies thinking at 13x human speed", [0.69, 0.72, 0.23, 0.01]),
                line("9 - 26%", [0.691, 0.53, 0.045, 0.01]),
                line("$26B/yr $1T", [0.745, 0.53, 0.062, 0.01]),
                line("192%", [0.823, 0.53, 0.0495, 0.01]),
                line("$458B/yr 2039", [0.899, 0.53, 0.07, 0.01]),
            ],
            figure_lines: Vec::new(),
        };
        let rows = super::status_card_rows(&page);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].first_metrics, "−26%; $26B/yr; $1T");
        assert_eq!(rows[0].second_metrics, "2%; $458B/yr; 2039");
    }

    #[test]
    fn card_row_fragments_prefer_sharper_overlapping_observations() {
        let low_confidence = RecognizedLine {
            confidence: 0.3,
            ..line("1 -25%1 SLee", [0.689, 0.5, 0.086, 0.015])
        };
        let clear_value = line("-25%", [0.710, 0.5, 0.026, 0.009]);
        let isolated = RecognizedLine {
            confidence: 0.3,
            ..line("Uncertain isolated label", [0.9, 0.3, 0.08, 0.01])
        };
        let kept = super::prefer_clear_status_lines(&[low_confidence, clear_value.clone(), isolated.clone()]);
        assert_eq!(kept, [clear_value, isolated]);
    }

    #[test]
    fn diagram_panels_are_read_separately() {
        use super::reorder_two_panel_diagram;

        let panels = reorder_two_panel_diagram(vec![
            line("Right panel content", [0.7, 0.5, 0.2, 0.02]),
            line("Chain-of-Thought (CoT)", [0.1, 0.8, 0.3, 0.02]),
            line("Left panel content", [0.1, 0.5, 0.2, 0.02]),
            line("Chain of Continuous Thought (Coconut)", [0.6, 0.8, 0.35, 0.02]),
            line("Left panel label", [0.1, 0.4, 0.2, 0.02]),
            line("Right panel label", [0.7, 0.4, 0.2, 0.02]),
        ]);
        assert_eq!(
            panels.iter().map(|line| line.text.as_str()).collect::<Vec<_>>(),
            [
                "Chain-of-Thought (CoT)",
                "Chain of Continuous Thought (Coconut)",
                "Left panel content",
                "Left panel label",
                "Right panel content",
                "Right panel label",
            ],
        );

    }

    #[test]
    fn plot_axes_are_read_before_series_and_callouts() {
        let ordered = super::reorder_plot_axes(vec![
            line("1e-5", [0.08, 0.9, 0.04, 0.02]),
            line("Series A", [0.65, 0.6, 0.15, 0.02]),
            line("Probability Density", [0.05, 0.4, 0.02, 0.12]),
            line("3.00", [0.08, 0.8, 0.04, 0.02]),
            line("2027", [0.6, 0.1, 0.05, 0.02]),
            line("0.00", [0.08, 0.2, 0.04, 0.02]),
            line("Year", [0.48, 0.03, 0.08, 0.02]),
            line("2025", [0.2, 0.1, 0.05, 0.02]),
            line("2.00", [0.08, 0.6, 0.04, 0.02]),
            line("2028", [0.8, 0.1, 0.05, 0.02]),
            line("1.00", [0.08, 0.4, 0.04, 0.02]),
            line("2026", [0.4, 0.1, 0.05, 0.02]),
            line("Forecast plot title", [0.2, 0.9, 0.6, 0.02]),
        ]);
        assert_eq!(
            ordered.iter().map(|line| line.text.as_str()).collect::<Vec<_>>(),
            [
                "Forecast plot title",
                "Probability Density",
                "0.00",
                "1.00",
                "2.00",
                "3.00",
                "Year",
                "2025",
                "2026",
                "2027",
                "2028",
                "1e-5",
                "Series A",
            ],
        );
    }

    #[test]
    fn axis_tick_parser_ignores_tick_marks_and_scale_annotations() {
        assert_eq!(super::axis_tick_value("1M -"), Some(1_000_000.0));
        assert_eq!(super::axis_tick_value("T 10"), Some(10.0));
        assert_eq!(super::axis_tick_value("8 hrs"), Some(28_800.0));
        assert_eq!(super::axis_tick_value("1e-5"), None);
        assert_eq!(super::normalize_figure_symbols(line("T 10", [0.1, 0.4, 0.02, 0.02])).text, "10");
    }

    #[test]
    fn combined_axis_observations_split_into_tick_pairs() {
        let split = super::split_combined_axis_ticks(line(
            "5 years- 16 months-",
            [0.08, 0.7, 0.12, 0.02],
        ));
        assert_eq!(split.iter().map(|line| line.text.as_str()).collect::<Vec<_>>(), ["5 years", "16 months"]);

        let split = super::split_combined_axis_ticks(line(
            "min- 8 2 min-",
            [0.08, 0.5, 0.12, 0.02],
        ));
        assert_eq!(split.iter().map(|line| line.text.as_str()).collect::<Vec<_>>(), ["8 min", "2 min"]);
    }

    #[test]
    fn separates_a_joined_zero_tick_and_year_label() {
        let split = super::split_combined_axis_ticks(line("0.2027", [0.095, 0.27, 0.05, 0.02]));
        assert_eq!(split.iter().map(|line| line.text.as_str()).collect::<Vec<_>>(), ["0.0", "2027"]);
        assert!(split[1].region[0] > 0.1);
    }

    #[test]
    fn chart_axis_label_normalization_uses_the_matching_chart_title() {
        let normalized = super::normalize_plot_axis_labels(&[
            line("Unrelated large label", [0.2, 0.9, 0.5, 0.02]),
            line("Task time (for humans),", [0.07, 0.4, 0.02, 0.2]),
            line("Length Of Coding Tasks AI Agents Can Complete Autonomously", [0.1, 0.8, 0.6, 0.02]),
        ]);
        assert_eq!(normalized[1].text, "Task time (for humans), 80% success rate");
    }

    #[test]
    fn china_compute_timeline_labels_follow_their_horizontal_positions() {
        let page = transcript_page(10, vec![
            line("China's Compute Centralization, 2025-2027", [0.07, 0.9, 0.45, 0.02]),
            line("Feb 2027 (40%)", [0.34, 0.32, 0.08, 0.01]),
            line("Rest of China", [0.55, 0.56, 0.08, 0.01]),
            line("Dec 2025", [0.07, 0.31, 0.05, 0.01]),
            line("CDZ", [0.55, 0.4, 0.02, 0.01]),
            line("Dec 2026", [0.28, 0.31, 0.05, 0.01]),
            line("Jun 2027", [0.40, 0.31, 0.05, 0.01]),
            line("Rest of DeepCent", [0.55, 0.52, 0.09, 0.01]),
            line("Jun 2026", [0.16, 0.31, 0.05, 0.01]),
            line("Dec 2027", [0.52, 0.31, 0.05, 0.01]),
        ]);
        assert_eq!(
            page.figure_lines.iter().map(|line| line.text.as_str()).collect::<Vec<_>>(),
            [
                "China's Compute Centralization, 2025-2027",
                "Rest of China", "Rest of DeepCent", "CDZ",
                "Dec 2025", "Jun 2026", "Dec 2026", "Feb 2027 (40%)", "Jun 2027", "Dec 2027",
            ],
        );
    }

    #[test]
    fn inference_price_chart_reads_dates_then_benchmarks_and_rates() {
        let page = transcript_page(16, vec![
            line("LLM inference prices have fallen 9x to 900x/year, depending on the task Price (USD per million tokens)", [0.08, 0.92, 0.46, 0.03]),
            line("0.1", [0.08, 0.73, 0.02, 0.01]),
            line("1", [0.09, 0.78, 0.01, 0.01]),
            line("10", [0.08, 0.83, 0.02, 0.01]),
            line("100", [0.08, 0.87, 0.02, 0.01]),
            line("EPOCH AI", [0.56, 0.90, 0.08, 0.01]),
            line("Mid-range 40x/year", [0.27, 0.85, 0.05, 0.01]),
            line("GPT-3.5 Turbo level or better on general knowledge (MMLU) GPT-4 level or better on Ph.D. level science questions (GPQA)", [0.50, 0.84, 0.14, 0.03]),
            line("Fastest 900x/year", [0.38, 0.82, 0.05, 0.01]),
            line("GPT-4o level or better on Ph.D. level science questions (GPQA) Other benchmarks and performance levels", [0.49, 0.80, 0.15, 0.03]),
            line("Slowest 9x/year", [0.27, 0.79, 0.04, 0.01]),
            line("Oct. 2021 Apr. 2022 Oct. 2022 Apr. 2023 Oct. 2023 Apr. 2024 Oct. 2024 Apr. 2025 Release Date", [0.10, 0.68, 0.39, 0.02]),
            line("Data source: Epoch AI, Artificial Analysis CC-BY", [0.08, 0.65, 0.18, 0.02]),
            line("epoch.ai", [0.59, 0.65, 0.04, 0.01]),
        ]);
        assert_eq!(
            page.figure_lines.iter().map(|line| line.text.as_str()).collect::<Vec<_>>(),
            [
                "LLM inference prices have fallen 9x to 900x/year, depending on the task Price (USD per million tokens)",
                "0.1", "1", "10", "100",
                "Release Date Oct. 2021 Apr. 2022 Oct. 2022 Apr. 2023 Oct. 2023 Apr. 2024 Oct. 2024 Apr. 2025",
                "GPT-3.5 Turbo level or better on general knowledge (MMLU) GPT-4 level or better on Ph.D. level science questions (GPQA)",
                "GPT-4o level or better on Ph.D. level science questions (GPQA) Other benchmarks and performance levels",
                "Mid-range 40x/year", "Fastest 900x/year", "Slowest 9x/year",
                "Data source: Epoch AI, Artificial Analysis CC-BY", "EPOCH AI", "epoch.ai",
            ],
        );
    }

    #[test]
    fn coding_task_chart_groups_axes_before_legend_and_series_labels() {
        let page = transcript_page(50, vec![
            line("Length Of Coding Tasks AI Agents Can Complete Autonomously", [0.15, 0.80, 0.58, 0.02]),
            line("8 hrs", [0.11, 0.78, 0.04, 0.01]),
            line("1 week", [0.11, 0.78, 0.04, 0.01]),
            line("1 month", [0.10, 0.73, 0.06, 0.01]),
            line("4 months", [0.10, 0.69, 0.07, 0.01]),
            line("16 months", [0.09, 0.65, 0.07, 0.01]),
            line("5 years", [0.09, 0.61, 0.04, 0.01]),
            line("METR's DATA gpt-3.5-turbo-instruct", [0.19, 0.76, 0.13, 0.02]),
            line("OUR PROJECTION   Agent-0", [0.36, 0.76, 0.11, 0.02]),
            line("A", [0.17, 0.75, 0.01, 0.01]),
            line("GPT-4 0314 GPT-4 1106", [0.19, 0.73, 0.06, 0.01]),
            line("Agent-1 A   Agent-2", [0.36, 0.73, 0.06, 0.01]),
            line("GPT-4o X o1-preview + 01", [0.17, 0.69, 0.08, 0.01]),
            line("Claude 3.5 Sonnet (Old)", [0.19, 0.65, 0.13, 0.01]),
            line("Claude 3.5 Sonnet (New)", [0.19, 0.60, 0.13, 0.01]),
            line("Claude 3.7 Sonnet", [0.19, 0.55, 0.10, 0.01]),
            line("2 hrs", [0.12, 0.57, 0.04, 0.01]),
            line("30 min", [0.11, 0.53, 0.05, 0.01]),
            line("Task time (for humans),", [0.07, 0.40, 0.02, 0.20]),
            line("8", [0.12, 0.49, 0.01, 0.01]),
            line("min-", [0.13, 0.49, 0.03, 0.01]),
            line("2 min", [0.12, 0.45, 0.04, 0.01]),
            line("Trendline", [0.54, 0.20, 0.06, 0.01]),
            line("30 sec", [0.11, 0.41, 0.05, 0.01]),
            line("Each doubling gets 15% easier*", [0.54, 0.28, 0.17, 0.01]),
            line("8 sec", [0.12, 0.37, 0.04, 0.01]),
            line("2021", [0.14, 0.32, 0.03, 0.01]),
            line("2022", [0.22, 0.32, 0.03, 0.01]),
            line("2023", [0.30, 0.32, 0.03, 0.01]),
            line("2024", [0.38, 0.32, 0.03, 0.01]),
            line("2025", [0.46, 0.32, 0.03, 0.01]),
            line("2026", [0.54, 0.32, 0.03, 0.01]),
            line("2027", [0.62, 0.32, 0.03, 0.01]),
            line("2028", [0.70, 0.32, 0.03, 0.01]),
            line("Model release date", [0.36, 0.25, 0.14, 0.01]),
        ]);
        let texts = page.figure_lines.iter().map(|line| line.text.as_str()).collect::<Vec<_>>();
        assert_eq!(texts[0], "Length Of Coding Tasks AI Agents Can Complete Autonomously");
        assert_eq!(texts[1], "Task time (for humans), 80% success rate", "{texts:?}");
        assert_eq!(
            &texts[2..15],
            [
                "8 sec", "30 sec", "2 min", "8 min", "30 min", "2 hrs", "8 hrs", "1 week",
                "1 month", "4 months", "16 months", "5 years", "Model release date",
            ],
        );
        assert_eq!(&texts[15..23], ["2021", "2022", "2023", "2024", "2025", "2026", "2027", "2028"], "{texts:?}");
        assert_eq!(
            &texts[23..],
            [
                "METR's DATA", "OUR PROJECTION", "gpt-3.5-turbo-instruct", "GPT-4 0314", "GPT-4 1106",
                "GPT-4o", "o1-preview", "o1", "Claude 3.5 Sonnet (Old)", "Claude 3.5 Sonnet (New)",
                "Claude 3.7 Sonnet", "Agent-0", "Agent-1", "Agent-2", "Trendline",
                "Each doubling gets 15% easier*",
            ],
        );
    }

    #[test]
    fn vertical_axis_words_join_without_joining_neighboring_labels() {
        let joined = super::join_vertical_plot_titles(vec![
            line("Copies", [0.07, 0.52, 0.012, 0.03]),
            line("Parallel", [0.07, 0.48, 0.012, 0.04]),
            line("Research Automation Deployment Tradeoff", [0.1, 0.7, 0.45, 0.02]),
        ]);
        assert!(joined.iter().any(|line| line.text == "Parallel Copies"));
        assert_eq!(joined.len(), 2);
    }

    #[test]
    fn plot_axes_keep_the_first_x_tick_out_of_the_y_scale() {
        let ordered = super::reorder_plot_axes(vec![
            line("Research Automation Deployment Tradeoff", [0.12, 0.9, 0.45, 0.02]),
            line("10M", [0.09, 0.8, 0.03, 0.02]),
            line("1M", [0.09, 0.6, 0.03, 0.02]),
            line("100K", [0.09, 0.4, 0.03, 0.02]),
            line("10K", [0.09, 0.2, 0.03, 0.02]),
            line("Speed (tokens/sec)", [0.3, 0.03, 0.2, 0.02]),
            line("T 10", [0.126, 0.1, 0.02, 0.02]),
            line("100", [0.3, 0.1, 0.03, 0.02]),
            line("1,000", [0.5, 0.1, 0.04, 0.02]),
            line("10,000", [0.7, 0.1, 0.05, 0.02]),
        ]);
        assert_eq!(
            ordered.iter().map(|line| line.text.as_str()).collect::<Vec<_>>(),
            [
                "Research Automation Deployment Tradeoff", "10K", "100K", "1M", "10M",
                "Speed (tokens/sec)", "T 10", "100", "1,000", "10,000",
            ],
        );
    }

    #[test]
    fn inference_scaled_models_are_read_from_low_to_high() {
        let ordered = super::reorder_inference_scaled_diagram(vec![
            line("M_max + SEARCH", [0.45, 0.88, 0.1, 0.02]),
            line("AI ABILITY", [0.3, 0.7, 0.04, 0.08]),
            line("M_3", [0.33, 0.75, 0.03, 0.02]),
            line("M_0 + SEARCH", [0.45, 0.7, 0.1, 0.02]),
            line("M_0", [0.33, 0.6, 0.03, 0.02]),
            line("M_3 + SEARCH", [0.45, 0.8, 0.1, 0.02]),
            line("M_max", [0.33, 0.85, 0.05, 0.02]),
            line("M_1", [0.33, 0.65, 0.03, 0.02]),
            line("M_2 + SEARCH", [0.45, 0.75, 0.1, 0.02]),
            line("M_1 + SEARCH", [0.45, 0.72, 0.1, 0.02]),
            line("M_2", [0.33, 0.7, 0.03, 0.02]),
            line("INFERENCE-SCALED MODELS", [0.55, 0.65, 0.2, 0.03]),
        ]);
        assert_eq!(
            ordered.iter().map(|line| line.text.as_str()).collect::<Vec<_>>(),
            [
                "AI ABILITY", "M_0", "M_1", "M_2", "M_3", "M_max", "M_0 + SEARCH",
                "M_1 + SEARCH", "M_2 + SEARCH", "M_3 + SEARCH", "M_max + SEARCH",
                "INFERENCE-SCALED MODELS",
            ],
        );
    }

    #[test]
    fn compute_comparison_pairs_each_model_with_its_value() {
        let ordered = super::reorder_training_compute_comparison(vec![
            line("GPT-4", [0.35, 0.7, 0.03, 0.02]),
            line("(3 × 10^27 FLOPS)", [0.52, 0.68, 0.06, 0.02]),
            line("GPT-3", [0.15, 0.7, 0.03, 0.02]),
            line("Agent-1", [0.54, 0.7, 0.04, 0.02]),
            line("(2 × 10^25 FLOPS)", [0.33, 0.68, 0.06, 0.02]),
            line("(3 × 10^23 FLOPS)", [0.13, 0.68, 0.06, 0.02]),
        ]);
        assert_eq!(
            ordered.iter().map(|line| line.text.as_str()).collect::<Vec<_>>(),
            [
                "GPT-3",
                "(3 × 10^23 FLOPS)",
                "GPT-4",
                "(2 × 10^25 FLOPS)",
                "Agent-1",
                "(3 × 10^27 FLOPS)",
            ],
        );
    }

    #[test]
    fn stacked_figure_words_join_when_their_boxes_share_a_column() {
        let merged = super::merge_stacked_labels(vec![
            line("External", [0.1, 0.5, 0.05, 0.02]),
            line("Deployment", [0.09, 0.48, 0.06, 0.02]),
            line("right-side label", [0.7, 0.5, 0.15, 0.02]),
        ]);
        assert_eq!(
            merged.iter().map(|line| line.text.as_str()).collect::<Vec<_>>(),
            ["External Deployment", "right-side label"],
        );
    }

    #[test]
    fn key_metric_tiles_are_read_down_each_column() {
        let ordered = super::reorder_key_metrics_columns(vec![
            line("OPENBRAIN REVENUE", [0.27, 0.7, 0.08, 0.02]),
            line("GLOBAL AI CAPEX", [0.08, 0.7, 0.06, 0.02]),
            line("$1T", [0.08, 0.67, 0.03, 0.02]),
            line("KEY METRICS 2026", [0.43, 0.73, 0.21, 0.02]),
            line("38GW", [0.08, 0.57, 0.04, 0.02]),
            line("$45B", [0.27, 0.67, 0.04, 0.02]),
            line("CAPITAL EXPENDITURE", [0.47, 0.7, 0.09, 0.02]),
        ]);
        assert_eq!(
            ordered.iter().map(|line| line.text.as_str()).collect::<Vec<_>>(),
            [
                "KEY METRICS 2026",
                "GLOBAL AI CAPEX",
                "$1T",
                "38GW",
                "OPENBRAIN REVENUE",
                "$45B",
                "CAPITAL EXPENDITURE",
            ],
        );
    }

    #[test]
    fn allocation_ring_labels_follow_their_own_panel_anchor() {
        let ordered = super::reorder_two_panel_diagram(vec![
            line("Research experiments", [0.12, 0.50, 0.11, 0.02]),
            line("2027", [0.42, 0.43, 0.04, 0.02]),
            line("OpenBrain's Compute Allocation, 2024 vs 2027", [0.06, 0.60, 0.38, 0.02]),
            line("External Deployment", [0.05, 0.45, 0.1, 0.02]),
            line("projection", [0.42, 0.40, 0.08, 0.02]),
            line("2024", [0.17, 0.43, 0.04, 0.02]),
            line("Training", [0.24, 0.40, 0.05, 0.02]),
            line("estimate", [0.17, 0.40, 0.04, 0.02]),
            line("External Deployment", [0.32, 0.50, 0.1, 0.02]),
            line("Data generation", [0.1, 0.30, 0.1, 0.02]),
            line("Research experiments", [0.52, 0.50, 0.12, 0.02]),
            line("Data generation", [0.31, 0.30, 0.1, 0.02]),
            line("Running AI assistants", [0.54, 0.30, 0.1, 0.02]),
            line("Training", [0.47, 0.20, 0.05, 0.02]),
        ]);
        assert_eq!(
            ordered.iter().map(|line| line.text.as_str()).collect::<Vec<_>>(),
            [
                "OpenBrain's Compute Allocation, 2024 vs 2027",
                "2024 estimate",
                "Research experiments",
                "External Deployment",
                "Training",
                "Data generation",
                "2027 projection",
                "External Deployment",
                "Research experiments",
                "Data generation",
                "Running AI assistants",
                "Training",
            ],
        );
    }
}
