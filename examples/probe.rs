// Throwaway experiment: dump span geometry for one page.
use pdf_oxide::PdfDocument;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let doc = PdfDocument::open(&a[1]).unwrap();
    let p: usize = a[2].parse().unwrap();
    println!("mediabox {:?}", doc.get_page_media_box(p - 1).unwrap());
    let mut spans = doc.extract_spans(p - 1).unwrap();
    spans.sort_by_key(|s| s.sequence);
    for s in spans {
        println!("{:4} x{:6.1} y{:6.1} w{:6.1} h{:5.1} sz{:4.1} {:?}{} rise{:.1} art{:?} {:?}",
            s.sequence, s.bbox.x, s.bbox.y, s.bbox.width, s.bbox.height, s.font_size,
            s.font_weight, if s.is_italic {"i"} else {""}, s.text_rise, s.artifact_type.is_some(), s.text.chars().take(70).collect::<String>());
    }
}
