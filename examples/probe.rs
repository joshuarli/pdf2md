// Throwaway experiment: dump span geometry for one page.
use pdf_oxide::PdfDocument;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let doc = PdfDocument::open(&a[1]).unwrap();
    let scan_tracking = a[2] == "scan";
    let pages: Vec<usize> = if scan_tracking {
        (0..doc.page_count().unwrap()).collect()
    } else {
        vec![a[2].parse::<usize>().unwrap() - 1]
    };
    for page in pages {
        if !scan_tracking {
            println!("page {} mediabox {:?}", page + 1, doc.get_page_media_box(page).unwrap());
        }
        let mut spans = doc.extract_spans(page).unwrap();
        spans.sort_by_key(|s| s.sequence);
        for s in spans {
            if scan_tracking && s.char_spacing <= 0.0 {
                continue;
            }
            println!("p{:3} {:4} x{:6.1} y{:6.1} w{:6.1} h{:5.1} sz{:4.1} cs{:5.2} {:?}{} rise{:.1} art{:?} {:?}",
                page + 1, s.sequence, s.bbox.x, s.bbox.y, s.bbox.width, s.bbox.height, s.font_size,
                s.char_spacing, s.font_weight, if s.is_italic {"i"} else {""}, s.text_rise, s.artifact_type.is_some(), s.text.chars().take(70).collect::<String>());
        }
    }
}
