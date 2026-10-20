import Testing
@testable import DuetKit

@Test(arguments: [
    ("Fix the build", DraftRoute.claude("Fix the build")),
    ("  @claude   what changed?  ", .claude("what changed?")),
    ("@all status, everyone?", .all("status, everyone?")),
    ("@qwen-27b add tests for the lexer", .worker(id: "qwen-27b", task: "add tests for the lexer")),
    ("@QWEN-9B\nrename foo", .worker(id: "qwen-9b", task: "rename foo")),
    ("@nobody hello", .claude("@nobody hello")),
    ("@qwen-27b", .claude("@qwen-27b")),
    ("email me at a@b.c", .claude("email me at a@b.c")),
])
func routesDrafts(input: String, expected: DraftRoute) {
    #expect(DraftRoute.route(input, workers: ["qwen-27b", "qwen-9b"]) == expected)
}

@Test func emptyDraftsGoNowhere() {
    #expect(DraftRoute.route("   \n ", workers: []) == nil)
}
