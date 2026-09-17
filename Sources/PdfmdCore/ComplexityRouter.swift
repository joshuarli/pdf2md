/// Complexity routing: which pages earn a model repair attempt (plan.md 26).
///
/// A handful of named signals, not a weighted heuristic. Simple prose never
/// routes; visual-layout ambiguity does. On macOS 26 the repair is
/// text-only, so image-dependent classes (multi-column order, dense overlap)
/// only route where structured context demonstrably helps — the benchmark
/// decides per class.
public struct ComplexityRouter: Sendable {
    public init() {}

    /// True when the page should be offered to the repair stage.
    /// - Parameter routeUncertainHeadings: the heading-hierarchy signal routes
    ///   only when structured-context repair demonstrably helps (plan.md 26);
    ///   the AI 2027 benchmark measured 33s per page of Apple Intelligence
    ///   wait for near-identical output, so the deterministic path keeps
    ///   heading decisions. Callers that want it back pass `true`.
    public func routesToRepair(_ page: PageIR, routeUncertainHeadings: Bool = false) -> Bool {
        let signals = page.complexity
        if signals.mergedCells { return true }
        if signals.nativeVisionDisagreement { return true }
        if routeUncertainHeadings, signals.uncertainHeadings, hasSufficientText(page) { return true }
        if signals.fragmentedOCR { return true }
        if signals.multiColumn || signals.denseOverlap {
            // Visual classes: worth it only with the page image (macOS 27+).
            if #available(macOS 27, *) { return true }
            return false
        }
        return false
    }

    private func hasSufficientText(_ page: PageIR) -> Bool {
        page.plainText.trimmingCharacters(in: .whitespacesAndNewlines).count > 200
    }
}
