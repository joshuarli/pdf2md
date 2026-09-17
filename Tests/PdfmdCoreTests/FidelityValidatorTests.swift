import Testing
@testable import PdfmdCore

let validator = FidelityValidator()

@Test func formattingOnlyChangesAccepted() {
    let result = validator.validate(
        deterministicText: "Hello world, this is a test of the system today.",
        repairedText: "# Hello world,\n\nthis is a **test** of the system today."
    )
    #expect(result == .accepted)
}

@Test func reorderedFaithfulTextAccepted() {
    let result = validator.validate(
        deterministicText: "First sentence here. Second sentence here. Third sentence here.",
        repairedText: "Second sentence here. First sentence here. Third sentence here."
    )
    #expect(result == .accepted)
}

@Test func hallucinatedParagraphRejected() {
    let result = validator.validate(
        deterministicText: "The cat sat on the mat quietly today.",
        repairedText: "The cat sat on the mat quietly today. Aliens then landed and gave a speech about interstellar trade policy and quantum governance."
    )
    if case .rejected = result { } else { Issue.record("expected rejection, got \(result)") }
}

@Test func largeOmissionRejected() {
    let result = validator.validate(
        deterministicText: "Alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu.",
        repairedText: "Alpha beta."
    )
    if case .rejected = result { } else { Issue.record("expected rejection, got \(result)") }
}

@Test func emptyAndRepetitiveRejected() {
    if case .rejected = validator.validate(deterministicText: "Some real content here.", repairedText: "   ") { }
    else { Issue.record("expected empty rejection") }
    let loop = [String](repeating: "the exact same sentence repeated endlessly here", count: 12).joined(separator: " ")
    if case .rejected = validator.validate(deterministicText: loop + " extra tail words to anchor", repairedText: loop) { }
    else { Issue.record("expected repetition rejection") }
}
