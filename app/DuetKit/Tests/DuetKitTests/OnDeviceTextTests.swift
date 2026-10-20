import Foundation
import Testing
@testable import DuetKit

// Text around Apple's on-device model, and the one-line verdicts read straight from tools' output.

@Test func aDigestIsStableAndNarrationIsLeftOut() {
    #expect(OnDeviceText.digest("same text") == OnDeviceText.digest("same text"))
    #expect(OnDeviceText.digest("one") != OnDeviceText.digest("two"))
    #expect(OnDeviceText.withoutNarration("Let me check the file.\n\nThe lexer skips escapes at line 27.") == "The lexer skips escapes at line 27.")
    #expect(OnDeviceText.withoutNarration("Let me check.") == "Let me check.", "nothing else to keep")
}

@Test func aModelsLineIsCleanedOrRefused() {
    #expect(OnDeviceText.line("Summary: \"The build failed in Lexer.swift.\"\nMore text") == "The build failed in Lexer.swift.")
    #expect(OnDeviceText.line("I'm sorry, I can't help with that.") == nil)
    #expect(OnDeviceText.line("") == nil)
    #expect(OnDeviceText.title("“Fixing the Lexer’s Escapes.”") == "Fixing the Lexer’s Escapes")
    #expect(OnDeviceText.title("Lexer") == nil, "one word isn't a name")
}

@Test func testRunnersVerdicts() {
    #expect(ToolOutput.verdict("✔ Test run with 85 tests in 0 suites passed after 1.3 seconds.") == "All 85 tests passed")
    #expect(ToolOutput.verdict("""
    ✘ Test lexerSkipsEscapes() recorded an issue at LexerTests.swift:12:5
    ✘ Test lexerSkipsEscapes() failed after 0.01 seconds with 1 issue.
    ✘ Test run with 40 tests in 0 suites failed after 0.5 seconds with 1 issue.
    """) == "1 issue in 40 tests: lexerSkipsEscapes")
    #expect(ToolOutput.verdict("""
    Test Case '-[ParserTests testEmpty]' failed (0.002 seconds).
    Executed 12 tests, with 1 failure (0 unexpected) in 0.031 (0.034) seconds
    """) == "1 of 12 tests failed: testEmpty")
    #expect(ToolOutput.verdict("""
    not ok 3 - auto picks an idle worker
    # tests 16
    # pass 15
    # fail 1
    """) == "1 of 16 tests failed: auto picks an idle worker")
    #expect(ToolOutput.verdict("# tests 4\n# pass 4\n# fail 0") == "All 4 tests passed")
    #expect(ToolOutput.verdict("  ✕ adds numbers (3 ms)\nTests:       1 failed, 41 passed, 42 total") == "1 of 42 tests failed: adds numbers")
    #expect(ToolOutput.verdict("FAILED tests/test_a.py::test_x - assert 1 == 2\n===== 1 failed, 9 passed in 0.12s =====") == "1 of 10 tests failed: tests/test_a.py::test_x")
    #expect(ToolOutput.verdict("test lexer::escapes ... FAILED\ntest result: FAILED. 7 passed; 1 failed; 0 ignored") == "1 of 8 tests failed: lexer::escapes")
}

@Test func compilersAndBuildsVerdicts() {
    #expect(ToolOutput.verdict("src/fleet.ts(12,3): error TS2345: Argument of type 'string' is not assignable.\nsrc/a.ts(1,1): error TS1005: ';' expected.")
            == "2 type errors, first fleet.ts:12 Argument of type 'string' is not assignable.")
    #expect(ToolOutput.verdict("/p/Sources/Lexer.swift:27:9: error: cannot find 'state' in scope\n** BUILD FAILED **") == "Build failed: 1 error, first Lexer.swift:27 cannot find 'state' in scope")
    #expect(ToolOutput.verdict("CompileSwift normal arm64\n** BUILD SUCCEEDED **") == "Build succeeded")
    #expect(ToolOutput.verdict("total 8\ndrwxr-xr-x  2 b staff 64 a") == nil, "not a run it knows")
}

@Test func anExcerptKeepsErrorsAndTheEnd() {
    let long = (1...400).map { "line \($0)" }.joined(separator: "\n") + "\nerror: disk full\n" + (401...500).map { "line \($0)" }.joined(separator: "\n")
    let e = ToolOutput.excerpt(long, limit: 1200)
    #expect(e.hasPrefix("error: disk full"))
    #expect(e.hasSuffix("line 500"))
    #expect(e.count <= 1300)
}
