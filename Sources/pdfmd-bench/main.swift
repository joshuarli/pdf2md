import CoreGraphics
import Darwin

import Foundation
import PdfmdCore

/// Benchmark runner (plan.md section 38). Deliberately a separate executable
/// so the normal `pdfmd --help` stays minimal.
///
/// ```text
/// pdfmd-bench ai2027 [--dir Benchmarks/AI2027]
/// pdfmd-bench raster-twin --pdf SRC --out DST [--dpi 300]
/// pdfmd-bench native-dump --pdf SRC --out DIR
/// pdfmd-bench font-dump --pdf SRC --out DIR
/// pdfmd-bench score --candidate CAND --golden GOLD
/// ```
///
/// `raster-twin` builds the raster-only benchmark twin (plan.md section 9);
/// `native-dump` writes per-page native text for golden curation and the
/// Baseline A sanity check; `font-dump` writes per-page lines annotated with
/// dominant type size, which separates headings, body, and footnote type
/// (golden curation and, later, heading inference).
private struct DisabledRepairer: ModelRepairing {
    var modelAvailable: Bool { false }
    func repair(page: PageIR, draft: String, pageImage: CGImage?) async -> String? { nil }
}

struct Bench {
    static func main() async -> Int32 {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            usage()
            return 2
        }
        args.removeFirst()
        switch command {
        case "ai2027":
            var directory = "Benchmarks/AI2027"
            if let flag = args.firstIndex(of: "--dir"), flag + 1 < args.endIndex {
                directory = args[flag + 1]
            }
            do {
                return try await runAI2027(directory: URL(fileURLWithPath: directory), repairEnabled: !args.contains("--no-repair"))
            } catch let error as BenchmarkError {
                writeErr(error.description + "\n")
                return 1
            } catch {
                writeErr("pdfmd-bench: \(error)\n")
                return 1
            }
        case "raster-twin":
            return rasterTwin(args: args)
        case "line-dump":
            return lineDump(args: args)
        case "native-dump":
            return nativeDump(args: args)
        case "font-dump":
            return fontDump(args: args)
        case "score":
            return score(args: args)
        default:
            usage()
            return 2
        }
    }

    static func usage() {
        writeErr("usage: pdfmd-bench ai2027 [--dir DIR]\n")
        writeErr("       pdfmd-bench raster-twin --pdf SRC --out DST [--dpi 300]\n")
        writeErr("       pdfmd-bench line-dump --pdf SRC --out DIR\n")
        writeErr("       pdfmd-bench native-dump --pdf SRC --out DIR\n")
        writeErr("       pdfmd-bench font-dump --pdf SRC --out DIR\n")
        writeErr("       pdfmd-bench score --candidate CAND --golden GOLD\n")
    }

    static func writeErr(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    /// Build the raster-only twin: every page re-rendered as an image-only
    /// PDF page, then verified to expose no meaningful native text layer.
    static func rasterTwin(args: [String]) -> Int32 {
        guard let pdf = flag("--pdf", in: args), let out = flag("--out", in: args) else {
            writeErr("usage: pdfmd-bench raster-twin --pdf SRC --out DST [--dpi 300]\n")
            return 2
        }
        let dpi = Double(flag("--dpi", in: args) ?? "300") ?? 300
        do {
            let source = try openPDF(at: URL(fileURLWithPath: pdf))
            writeErr("pdfmd-bench: rendering \(source.pageCount) pages at \(Int(dpi)) DPI\n")
            let twin = try buildRasterOnlyTwin(source: source, dpi: CGFloat(dpi))
            twin.write(to: URL(fileURLWithPath: out))
            guard !twinHasNativeText(twin) else {
                writeErr("pdfmd-bench: twin still exposes a native text layer; refusing\n")
                return 1
            }
            writeErr("pdfmd-bench: wrote \(out) (\(twin.pageCount) image-only pages)\n")
            return 0
        } catch {
            writeErr("pdfmd-bench: \(error)\n")
            return 1
        }
    }

    /// Dump `PDFPage.string` per page for golden curation and Baseline A.
    /// One file per page; no markers, so the join scores cleanly.
    static func nativeDump(args: [String]) -> Int32 {
        guard let pdf = flag("--pdf", in: args), let out = flag("--out", in: args) else {
            writeErr("usage: pdfmd-bench native-dump --pdf SRC --out DIR\n")
            return 2
        }
        do {
            let document = try openPDF(at: URL(fileURLWithPath: pdf))
            let directory = URL(fileURLWithPath: out)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let padded = String(repeating: "0", count: max(0, 4 - String(index + 1).count)) + String(index + 1)
                try Data((page.string ?? "").utf8).write(to: directory.appendingPathComponent("page-\(padded).txt"))
            }
            writeErr("pdfmd-bench: dumped \(document.pageCount) pages to \(out)\n")
            return 0
        } catch {
            writeErr("pdfmd-bench: \(error)\n")
            return 1
        }
    }

    /// Dump PDFKit selection-line text with normalized top-left rects as
    /// `x,y,w,h<TAB>TEXT` TSV per page. Evidence for native/Vision spatial
    /// reconciliation (plan.md section 21).
    static func lineDump(args: [String]) -> Int32 {
        guard let pdf = flag("--pdf", in: args), let out = flag("--out", in: args) else {
            writeErr("usage: pdfmd-bench line-dump --pdf SRC --out DIR\n")
            return 2
        }
        do {
            let document = try openPDF(at: URL(fileURLWithPath: pdf))
            let directory = URL(fileURLWithPath: out)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let lines = nativeTextLines(of: page)
                let body = lines.map {
                    unsafe String(format: "%.4f,%.4f,%.4f,%.4f\t%@",
                           $0.region.x, $0.region.y, $0.region.width, $0.region.height, $0.text)
                }.joined(separator: "\n")
                let padded = String(repeating: "0", count: max(0, 4 - String(index + 1).count)) + String(index + 1)
                try Data(body.utf8).write(to: directory.appendingPathComponent("page-\(padded).tsv"))
            }
            writeErr("pdfmd-bench: dumped \(document.pageCount) pages to \(out)\n")
            return 0
        } catch {
            writeErr("pdfmd-bench: \(error)\n")
            return 1
        }
    }

    static func flag(_ name: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.endIndex else { return nil }
        return args[i + 1]
    }

    /// Score a candidate Markdown file against golden Markdown.
    static func score(args: [String]) -> Int32 {
        guard let cand = flag("--candidate", in: args), let gold = flag("--golden", in: args) else {
            writeErr("usage: pdfmd-bench score --candidate CAND --golden GOLD\n")
            return 2
        }
        do {
            let candidate = try String(contentsOfFile: cand, encoding: .utf8)
            let golden = try String(contentsOfFile: gold, encoding: .utf8)
            print(formatScoreReport(title: "score", report: scoreMarkdown(candidate: candidate, golden: golden)))
            return 0
        } catch {
            writeErr("pdfmd-bench: \(error)\n")
            return 1
        }
    }

    /// Dump per-page lines as `SIZE\\tTEXT` TSV, SIZE being the dominant
    /// type size in points. Separates display type (titles/headings), body,
    /// and small type (footnotes, captions) for curation.
    static func fontDump(args: [String]) -> Int32 {
        guard let pdf = flag("--pdf", in: args), let out = flag("--out", in: args) else {
            writeErr("usage: pdfmd-bench font-dump --pdf SRC --out DIR\n")
            return 2
        }
        do {
            let document = try openPDF(at: URL(fileURLWithPath: pdf))
            let directory = URL(fileURLWithPath: out)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let lines = fontLines(of: page)
                let body = lines.map { "\(($0.size * 10).rounded() / 10)\t\($0.text)" }.joined(separator: "\n")
                let padded = String(repeating: "0", count: max(0, 4 - String(index + 1).count)) + String(index + 1)
                try Data(body.utf8).write(to: directory.appendingPathComponent("page-\(padded).tsv"))
            }
            writeErr("pdfmd-bench: dumped \(document.pageCount) pages to \(out)\n")
            return 0
        } catch {
            writeErr("pdfmd-bench: \(error)\n")
            return 1
        }
    }

    static func runAI2027(directory: URL, repairEnabled: Bool = true) async throws -> Int32 {
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(BenchmarkManifest.self, from: data)
        let pdfURL = directory.appendingPathComponent(manifest.sourceFilename)
        let rasterURL = directory.appendingPathComponent(manifest.rasterFilename)
        let goldenURL = directory.appendingPathComponent(manifest.goldenFilename)

        try validateBenchmarkSource(at: pdfURL, manifest: manifest)
        guard FileManager.default.fileExists(atPath: goldenURL.path) else {
            throw BenchmarkError.unreadable(goldenURL.path + " (see Benchmarks/AI2027/README.md to create it)")
        }
        let golden = try String(contentsOf: goldenURL, encoding: .utf8)
        let pipeline = repairEnabled ? Pipeline() : Pipeline(repairer: DisabledRepairer())
        let artifacts = directory.appendingPathComponent(repairEnabled ? "results-repair" : "results-deterministic")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        print("repair: \(repairEnabled ? "enabled" : "disabled")")
        let started = Date()

        let bornDigital = try await pipeline.convertWithPageDrafts(
            pdfURL: pdfURL,
            options: CliOptions(input: pdfURL.path),
            progress: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        )
        try writeAtomically(bornDigital.markdown, to: artifacts.appendingPathComponent("born.md"))
        try JSONEncoder().encode(bornDigital.pageDrafts).write(to: artifacts.appendingPathComponent("born-pages.json"))
        let bornReport = scoreMarkdown(candidate: bornDigital.markdown, golden: golden)
        print("AI 2027 — born digital\n")
        print(formatScoreReport(title: "born digital", report: bornReport))

        let raster = try await pipeline.convertWithPageDrafts(
            pdfURL: rasterURL,
            options: CliOptions(input: rasterURL.path),
            progress: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        )
        try writeAtomically(raster.markdown, to: artifacts.appendingPathComponent("raster.md"))
        try JSONEncoder().encode(raster.pageDrafts).write(to: artifacts.appendingPathComponent("raster-pages.json"))
        let rasterReport = scoreMarkdown(candidate: raster.markdown, golden: golden)
        print("AI 2027 — raster\n")
        print(formatScoreReport(title: "raster", report: rasterReport))

        let elapsed = Date().timeIntervalSince(started)
        print("wall-clock: \((elapsed * 10).rounded() / 10)s")

        let bornPass = bornReport.textMatch >= manifest.bornDigitalTextMatch
        let rasterPass = rasterReport.textMatch >= manifest.rasterTextMatch
            && rasterReport.novelText <= manifest.rasterNovelText
        print(bornPass && rasterPass ? "PASS" : "FAIL")
        return bornPass && rasterPass ? 0 : 1
    }
}

let code = await Bench.main()
exit(code)
