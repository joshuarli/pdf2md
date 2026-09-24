// Throwaway: font-size histogram (chars) for the doc, plus per-page odd sizes.
use pdf_oxide::PdfDocument;
use std::collections::BTreeMap;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let doc = PdfDocument::open(&a[1]).unwrap();
    let mut h: BTreeMap<i32, (usize, String)> = BTreeMap::new();
    for p in 0..doc.page_count().unwrap() {
        for s in doc.extract_spans(p).unwrap() {
            let k = (s.font_size * 10.0).round() as i32;
            let e = h.entry(k).or_insert((0, String::new()));
            e.0 += s.text.chars().count();
            if e.1.len() < 60 { e.1 = format!("p{} {}", p + 1, s.text.chars().take(50).collect::<String>()); }
        }
    }
    for (k, (n, ex)) in h { println!("{:5.1} {:7} {}", k as f32 / 10.0, n, ex); }
}
