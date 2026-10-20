#if DEBUG
import DuetKit
import SwiftUI

/// A realistic moment, as hub events: an earlier conversation (a finished task with a diff, a diagram in two
/// versions), then the live one with Claude mid-turn waiting for an approval, its plan, workers busy, a worker's
/// question Claude passed on to you and a GPU swap waiting on you. Decoded with the app's own protocol code, so
/// previews show exactly what a live hub would.
@MainActor
enum PreviewData {
    static let t0 = Date().timeIntervalSince1970 * 1000 - 95_000

    static let lines: [String] = [
        #"{"seq":1,"ts":T,"type":"session","state":"ready","sessionId":"s1","model":"claude-opus-5-5","account":{"subscription":"Claude Max"},"conversationId":"s1"}"#,
        #"{"seq":2,"ts":T,"type":"lead_info","model":"claude-opus-5-5","effort":"high","cwd":"/home/you/projects/parser","models":[{"value":"opus","displayName":"Opus 5.5","effortLevels":["low","medium","high","xhigh","max"],"resolved":"claude-opus-5-5"},{"value":"sonnet","displayName":"Sonnet 5.5","effortLevels":["low","medium","high","xhigh","max"],"resolved":"claude-sonnet-5-5"},{"value":"haiku","displayName":"Haiku 5.5","effortLevels":["low","medium","high","xhigh","max"],"resolved":"claude-haiku-5-5"}],"conversationId":"s1"}"#,
        #"{"seq":3,"ts":T,"type":"model_catalog","models":[{"id":"qwen3.8-27b","device":"r9700","loaded":true,"evicts":[],"effortLevels":["off","medium","xhigh"],"verified":true},{"id":"qwen3.5-9b-3060","device":"rtx3060","loaded":true,"evicts":[],"effortLevels":["off","on"],"verified":true},{"id":"gemma4-26b","device":"rtx3060","loaded":false,"evicts":["qwen3.5-9b-3060"],"effortLevels":["off","on"],"verified":false}]}"#,
        #"{"seq":4,"ts":T,"type":"fleet","workers":[{"id":"qwen-27b","label":"Qwen3.8 27B · R9700","backend":"llmd","model":"qwen3.8-27b","enabled":true,"available":true,"loaded":true,"effort":"medium","effortLevels":["off","medium","xhigh"],"tokPerS":164.3,"verifiedEffort":true,"running":"t-a1","queue":[]},{"id":"qwen-9b","label":"9B · RTX 3060","backend":"llmd","model":"qwen3.5-9b-3060","enabled":true,"available":true,"loaded":true,"effort":"off","effortLevels":["off","on"],"tokPerS":38.9,"verifiedEffort":true,"running":"t-b2","queue":["t-c3"]},{"id":"mac-9b","label":"Ornith 9B · Mac","backend":"ollama","model":"hf.co/ornith-ai/Ornith-1.5-9B-GGUF:Q8_0","enabled":false,"available":false,"loaded":false,"effort":"off","effortLevels":["off","on"],"verifiedEffort":true,"running":null,"queue":[]},{"id":"claude-explore","label":"Explore · Claude subagent","backend":"claude","model":"claude","enabled":true,"available":true,"loaded":true,"effort":"default","effortLevels":[],"running":null,"queue":[]},{"id":"claude-general-purpose","label":"General-purpose · Claude subagent","backend":"claude","model":"claude","enabled":true,"available":true,"loaded":true,"effort":"default","effortLevels":[],"running":null,"queue":[]}]}"#,
        // The earlier conversation: a rename handed to a worker, and a diagram revised once.
        #"{"seq":5,"ts":T,"type":"user","turn":1,"text":"Explain the lexer's state machine, then rename Token.text to Token.lexeme across the package.","by":"mac","conversationId":"s1"}"#,
        #"{"seq":6,"ts":T,"type":"turn_start","turn":1,"conversationId":"s1"}"#,
        #"{"seq":7,"ts":T,"type":"assistant","turn":1,"text":"The lexer is a two-state machine: `Start` scans whitespace, numbers and punctuation; a quote moves it into `InString`, which runs to the closing quote (escapes stay in the string) and drops back to `Start`.\n\nThe rename is mechanical, so a worker can do it while I draw the states.","toolUses":[{"id":"u0","name":"mcp__duet__delegate","input":{"worker":"qwen-27b","task":"Rename Token.text to Token.lexeme across the package."}}],"conversationId":"s1"}"#,
        // Claude's subagents: three side by side (two done, one failed), two sent to the background, and a workflow.
        #"{"seq":8,"ts":T,"type":"assistant","turn":1,"text":"","toolUses":[{"id":"toolu_mapstat1","name":"Agent","input":{"description":"Map the lexer's states","prompt":"List every state of the lexer in Sources/Parser/Lexer.swift and what moves it between them.","subagent_type":"Explore"}},{"id":"toolu_finduse1","name":"Agent","input":{"description":"Find every Token.text use","prompt":"Find every use of Token.text in the package, with its file and line.","subagent_type":"Explore"}},{"id":"toolu_chktest1","name":"Agent","input":{"description":"Check the lexer tests","prompt":"Run the lexer tests and say which fail and why.","subagent_type":"General-purpose"}}],"conversationId":"s1"}"#,
        #"{"seq":9,"ts":T,"type":"task","taskId":"sa-mapstat1","worker":"claude-explore","state":"running","prompt":"List every state of the lexer in Sources/Parser/Lexer.swift and what moves it between them.","by":"lead","effort":"default","cwd":"/home/you/projects/parser","conversationId":"s1"}"#,
        #"{"seq":10,"ts":T,"type":"dialogue","id":"sa-mapstat1-task","kind":"TASK","taskId":"sa-mapstat1","from":"lead","to":"claude-explore","text":"List every state of the lexer in Sources/Parser/Lexer.swift and what moves it between them.","conversationId":"s1"}"#,
        #"{"seq":11,"ts":T,"type":"task","taskId":"sa-finduse1","worker":"claude-explore","state":"running","prompt":"Find every use of Token.text in the package, with its file and line.","by":"lead","effort":"default","cwd":"/home/you/projects/parser","conversationId":"s1"}"#,
        #"{"seq":12,"ts":T,"type":"dialogue","id":"sa-finduse1-task","kind":"TASK","taskId":"sa-finduse1","from":"lead","to":"claude-explore","text":"Find every use of Token.text in the package, with its file and line.","conversationId":"s1"}"#,
        #"{"seq":13,"ts":T,"type":"task","taskId":"sa-chktest1","worker":"claude-general-purpose","state":"running","prompt":"Run the lexer tests and say which fail and why.","by":"lead","effort":"default","cwd":"/home/you/projects/parser","conversationId":"s1"}"#,
        #"{"seq":14,"ts":T,"type":"dialogue","id":"sa-chktest1-task","kind":"TASK","taskId":"sa-chktest1","from":"lead","to":"claude-general-purpose","text":"Run the lexer tests and say which fail and why.","conversationId":"s1"}"#,
        #"{"seq":15,"ts":T,"type":"task","taskId":"sa-mapstat1","worker":"claude-explore","state":"done","result":"Two states, Start and InString: a quote moves between them, and a backslash inside a string keeps the next character.","evidence":"no changes","conversationId":"s1"}"#,
        #"{"seq":16,"ts":T,"type":"dialogue","id":"sa-mapstat1-result","kind":"RESULT","taskId":"sa-mapstat1","from":"claude-explore","to":"lead","text":"Finished: Two states, Start and InString: a quote moves between them, and a backslash inside a string keeps the next character.","conversationId":"s1"}"#,
        #"{"seq":17,"ts":T,"type":"tool_result","turn":1,"toolUseId":"toolu_mapstat1","isError":false,"preview":"Two states, Start and InString: a quote moves between them, and a backslash inside a string keeps the next character.","conversationId":"s1"}"#,
        #"{"seq":18,"ts":T,"type":"task","taskId":"sa-finduse1","worker":"claude-explore","state":"done","result":"Token.text is used in 4 files: Lexer.swift:41, Parser.swift:18 and 52, Token.swift:6, ParserTests.swift:12.","evidence":"no changes","conversationId":"s1"}"#,
        #"{"seq":19,"ts":T,"type":"dialogue","id":"sa-finduse1-result","kind":"RESULT","taskId":"sa-finduse1","from":"claude-explore","to":"lead","text":"Finished: Token.text is used in 4 files: Lexer.swift:41, Parser.swift:18 and 52, Token.swift:6, ParserTests.swift:12.","conversationId":"s1"}"#,
        #"{"seq":20,"ts":T,"type":"tool_result","turn":1,"toolUseId":"toolu_finduse1","isError":false,"preview":"Token.text is used in 4 files: Lexer.swift:41, Parser.swift:18 and 52, Token.swift:6, ParserTests.swift:12.","conversationId":"s1"}"#,
        #"{"seq":21,"ts":T,"type":"task","taskId":"sa-chktest1","worker":"claude-general-purpose","state":"failed","result":"swift test could not build: ParserTests.swift:12 calls an initializer that no longer exists.","evidence":"no changes","conversationId":"s1"}"#,
        #"{"seq":22,"ts":T,"type":"dialogue","id":"sa-chktest1-result","kind":"RESULT","taskId":"sa-chktest1","from":"claude-general-purpose","to":"lead","text":"Failed: swift test could not build: ParserTests.swift:12 calls an initializer that no longer exists.","conversationId":"s1"}"#,
        #"{"seq":23,"ts":T,"type":"tool_result","turn":1,"toolUseId":"toolu_chktest1","isError":true,"preview":"swift test could not build: ParserTests.swift:12 calls an initializer that no longer exists.","conversationId":"s1"}"#,
        #"{"seq":24,"ts":T,"type":"assistant","turn":1,"text":"","toolUses":[{"id":"toolu_benchlx1","name":"Agent","input":{"description":"Benchmark the lexer","prompt":"Time the lexer on a 5 MB file before and after the rename.","subagent_type":"General-purpose","run_in_background":true}},{"id":"toolu_profscn1","name":"Agent","input":{"description":"Profile scanString","prompt":"Profile scanString on very long strings.","subagent_type":"General-purpose","run_in_background":true}}],"conversationId":"s1"}"#,
        #"{"seq":25,"ts":T,"type":"task","taskId":"sa-benchlx1","worker":"claude-general-purpose","state":"running","prompt":"Time the lexer on a 5 MB file before and after the rename.","by":"lead","effort":"default","cwd":"/home/you/projects/parser","conversationId":"s1"}"#,
        #"{"seq":26,"ts":T,"type":"dialogue","id":"sa-benchlx1-task","kind":"TASK","taskId":"sa-benchlx1","from":"lead","to":"claude-general-purpose","text":"Time the lexer on a 5 MB file before and after the rename.","conversationId":"s1"}"#,
        #"{"seq":27,"ts":T,"type":"task","taskId":"sa-profscn1","worker":"claude-general-purpose","state":"running","prompt":"Profile scanString on very long strings.","by":"lead","effort":"default","cwd":"/home/you/projects/parser","conversationId":"s1"}"#,
        #"{"seq":28,"ts":T,"type":"dialogue","id":"sa-profscn1-task","kind":"TASK","taskId":"sa-profscn1","from":"lead","to":"claude-general-purpose","text":"Profile scanString on very long strings.","conversationId":"s1"}"#,
        #"{"seq":29,"ts":T,"type":"task","taskId":"sa-benchlx1","worker":"claude-general-purpose","state":"done","result":"Running in the background; Claude gets its report when it finishes.","evidence":"no changes","conversationId":"s1"}"#,
        #"{"seq":30,"ts":T,"type":"dialogue","id":"sa-benchlx1-result","kind":"RESULT","taskId":"sa-benchlx1","from":"claude-general-purpose","to":"lead","text":"Finished: Running in the background; Claude gets its report when it finishes.","conversationId":"s1"}"#,
        #"{"seq":31,"ts":T,"type":"tool_result","turn":1,"toolUseId":"toolu_benchlx1","isError":false,"preview":"Running in the background; Claude gets its report when it finishes.","conversationId":"s1"}"#,
        #"{"seq":32,"ts":T,"type":"task","taskId":"sa-profscn1","worker":"claude-general-purpose","state":"done","result":"Running in the background; Claude gets its report when it finishes.","evidence":"no changes","conversationId":"s1"}"#,
        #"{"seq":33,"ts":T,"type":"dialogue","id":"sa-profscn1-result","kind":"RESULT","taskId":"sa-profscn1","from":"claude-general-purpose","to":"lead","text":"Finished: Running in the background; Claude gets its report when it finishes.","conversationId":"s1"}"#,
        #"{"seq":34,"ts":T,"type":"tool_result","turn":1,"toolUseId":"toolu_profscn1","isError":false,"preview":"Running in the background; Claude gets its report when it finishes.","conversationId":"s1"}"#,
        #"{"seq":35,"ts":T,"type":"assistant","turn":1,"text":"","toolUses":[{"id":"toolu_wflexer1","name":"Workflow","input":{"script":"export const meta = {\n  name: 'lexer-audit',\n  description: 'Audit the lexer and its tests',\n}\nphase('Read')\n"}}],"conversationId":"s1"}"#,
        #"{"seq":36,"ts":T,"type":"tool_result","turn":1,"toolUseId":"toolu_wflexer1","isError":false,"preview":"{\"status\":\"async_launched\",\"runId\":\"wf_lexer-audit\"}","conversationId":"s1"}"#,
        #"{"seq":37,"ts":T,"type":"dialogue","id":"t-x0","kind":"TASK","taskId":"t-d4","from":"lead","to":"qwen-27b","text":"Rename Token.text to Token.lexeme across the package.","conversationId":"s1"}"#,
        #"{"seq":38,"ts":T,"type":"task","taskId":"t-d4","worker":"qwen-27b","state":"running","prompt":"Rename Token.text to Token.lexeme across the package.","by":"lead","effort":"medium","cwd":"/home/you/projects/parser","conversationId":"s1"}"#,
        #"{"seq":39,"ts":T,"type":"diagram","id":"g1","version":1,"title":"Lexer states","kind":"mermaid","source":"stateDiagram-v2\n    [*] --> Start\n    Start --> InString: quote\n    InString --> Start: closing quote","caption":"How scanString re-enters Start","by":"lead","conversationId":"s1"}"#,
        #"{"seq":40,"ts":T,"type":"task","taskId":"t-d4","worker":"qwen-27b","state":"done","result":"Renamed Token.text to Token.lexeme in 4 files; all tests pass.","evidence":"diff --stat:\n Sources/Parser/Lexer.swift  | 18 +++---\n Sources/Parser/Parser.swift | 24 ++++----\n Tests/ParserTests.swift     |  6 +-\n 3 files changed, 25 insertions(+), 23 deletions(-)","stats":{"requests":6,"inputTokens":18120,"outputTokens":1310,"genTokPerS":171.2,"wallMs":14200,"firstTokenMs":520},"conversationId":"s1"}"#,
        #"{"seq":41,"ts":T,"type":"dialogue","id":"r-d4","kind":"RESULT","taskId":"t-d4","from":"qwen-27b","to":"lead","text":"Finished: Renamed Token.text to Token.lexeme in 4 files; all tests pass.\nHub-measured changes:\n3 files changed, 25 insertions(+), 23 deletions(-)","conversationId":"s1"}"#,
        #"{"seq":42,"ts":T,"type":"diagram","id":"g1","version":2,"title":"Lexer states","kind":"mermaid","source":"stateDiagram-v2\n    [*] --> Start\n    Start --> InString: quote\n    InString --> Escape: backslash\n    Escape --> InString\n    InString --> Start: closing quote","caption":"With the escape state the rename touched","by":"lead","explains":[{"path":"/home/you/projects/parser/Sources/Parser/Lexer.swift","start":27,"end":41}],"links":{"Start":"/home/you/projects/parser/Sources/Parser/Lexer.swift:29-31","InString":"/home/you/projects/parser/Sources/Parser/Lexer.swift:32-35","Escape":"/home/you/projects/parser/Sources/Parser/Lexer.swift:36-39"},"conversationId":"s1"}"#,
        #"{"seq":43,"ts":T,"type":"turn_end","turn":1,"subtype":"success","isError":false,"interrupted":false,"durationMs":41000,"conversationId":"s1"}"#,
        #"{"seq":44,"ts":T,"type":"context","action":"cleared","by":"mac","conversationId":"s2"}"#,
        #"{"seq":45,"ts":T,"type":"session","state":"ready","sessionId":"s2","model":"claude-opus-5-5","conversationId":"s2"}"#,
        // The live conversation.
        #"{"seq":46,"ts":T,"type":"user","turn":2,"text":"Refactor the parser so tokens carry their source ranges, and add tests for the error cases.","by":"mac","conversationId":"s2"}"#,
        #"{"seq":47,"ts":T,"type":"turn_start","turn":2,"conversationId":"s2"}"#,
        #"{"seq":48,"ts":T,"type":"assistant","turn":2,"text":"I'll split this in two and run them in parallel:\n\n1. **Source ranges** → `qwen-27b`: change `Token` to carry a `Range<String.Index>`, update the lexer.\n2. **Error-case tests** → `qwen-9b`: unterminated strings, bad escapes, unexpected EOF.\n\n```swift\nstruct Token: Equatable {\n    let kind: Kind\n    let range: Range<String.Index>\n}\n```","toolUses":[{"id":"u1","name":"mcp__duet__delegate","input":{"worker":"qwen-27b","task":"Add source ranges to Token"}},{"id":"u2","name":"mcp__duet__delegate","input":{"worker":"qwen-9b","task":"Tests for parser error cases"}}],"conversationId":"s2"}"#,
        #"{"seq":49,"ts":T,"type":"tool_result","turn":2,"toolUseId":"u1","isError":false,"preview":"Delegated as t-a1.","conversationId":"s2"}"#,
        // Three of Claude's subagents, one done and two still running.
        #"{"seq":50,"ts":T,"type":"assistant","turn":2,"text":"","toolUses":[{"id":"toolu_rngtest1","name":"Agent","input":{"description":"Find the range tests","prompt":"Find the tests that check token ranges.","subagent_type":"Explore"}},{"id":"toolu_rngedge1","name":"Agent","input":{"description":"Check ranges at the edges","prompt":"Check token ranges at the start and end of the input.","subagent_type":"Explore"}},{"id":"toolu_rngdocs1","name":"Agent","input":{"description":"Read the range docs","prompt":"Read the docs on String.Index ranges.","subagent_type":"Explore"}}],"conversationId":"s2"}"#,
        #"{"seq":51,"ts":T,"type":"task","taskId":"sa-rngtest1","worker":"claude-explore","state":"running","prompt":"Find the tests that check token ranges.","by":"lead","effort":"default","cwd":"/home/you/projects/parser","conversationId":"s2"}"#,
        #"{"seq":52,"ts":T,"type":"dialogue","id":"sa-rngtest1-task","kind":"TASK","taskId":"sa-rngtest1","from":"lead","to":"claude-explore","text":"Find the tests that check token ranges.","conversationId":"s2"}"#,
        #"{"seq":53,"ts":T,"type":"task","taskId":"sa-rngedge1","worker":"claude-explore","state":"running","prompt":"Check token ranges at the start and end of the input.","by":"lead","effort":"default","cwd":"/home/you/projects/parser","conversationId":"s2"}"#,
        #"{"seq":54,"ts":T,"type":"dialogue","id":"sa-rngedge1-task","kind":"TASK","taskId":"sa-rngedge1","from":"lead","to":"claude-explore","text":"Check token ranges at the start and end of the input.","conversationId":"s2"}"#,
        #"{"seq":55,"ts":T,"type":"task","taskId":"sa-rngdocs1","worker":"claude-explore","state":"running","prompt":"Read the docs on String.Index ranges.","by":"lead","effort":"default","cwd":"/home/you/projects/parser","conversationId":"s2"}"#,
        #"{"seq":56,"ts":T,"type":"dialogue","id":"sa-rngdocs1-task","kind":"TASK","taskId":"sa-rngdocs1","from":"lead","to":"claude-explore","text":"Read the docs on String.Index ranges.","conversationId":"s2"}"#,
        #"{"seq":57,"ts":T,"type":"task","taskId":"sa-rngtest1","worker":"claude-explore","state":"done","result":"Ranges are tested only in LexerTests.testIdentifiers; none cover strings or errors.","evidence":"no changes","conversationId":"s2"}"#,
        #"{"seq":58,"ts":T,"type":"dialogue","id":"sa-rngtest1-result","kind":"RESULT","taskId":"sa-rngtest1","from":"claude-explore","to":"lead","text":"Finished: Ranges are tested only in LexerTests.testIdentifiers; none cover strings or errors.","conversationId":"s2"}"#,
        #"{"seq":59,"ts":T,"type":"tool_result","turn":2,"toolUseId":"toolu_rngtest1","isError":false,"preview":"Ranges are tested only in LexerTests.testIdentifiers; none cover strings or errors.","conversationId":"s2"}"#,
        #"{"seq":60,"ts":T,"type":"dialogue","id":"t-x1","kind":"TASK","taskId":"t-a1","from":"lead","to":"qwen-27b","text":"Add source ranges to Token","conversationId":"s2"}"#,
        #"{"seq":61,"ts":T,"type":"task","taskId":"t-a1","worker":"qwen-27b","state":"running","prompt":"Change Token to carry a Range<String.Index> and update the lexer to fill it in.","by":"lead","effort":"medium","cwd":"/home/you/projects/parser","profile":"implement","conversationId":"s2"}"#,
        #"{"seq":62,"ts":T,"type":"task_progress","taskId":"t-a1","worker":"qwen-27b","tools":["Edit Sources/Parser/Lexer.swift"],"conversationId":"s2"}"#,
        #"{"seq":63,"ts":T,"type":"task","taskId":"t-b2","worker":"qwen-9b","state":"running","prompt":"Write Swift Testing tests for unterminated strings, bad escapes and unexpected EOF.","by":"lead","effort":"off","profile":"test","conversationId":"s2"}"#,
        #"{"seq":64,"ts":T,"type":"dialogue","id":"q-77","kind":"QUESTION","taskId":"t-b2","from":"qwen-9b","to":"lead","text":"Should the tests live in ParserTests.swift or a new ParserErrorTests.swift?","options":["ParserTests.swift","New ParserErrorTests.swift"],"conversationId":"s2"}"#,
        #"{"seq":65,"ts":T,"type":"swap_request","id":"s-9","taskId":"t-c3","worker":"qwen-9b","model":"gemma4-26b","device":"rtx3060","evicts":["qwen3.5-9b-3060"],"conversationId":"s2"}"#,
        #"{"seq":66,"ts":T,"type":"approval_request","id":"ap1","turn":2,"tool":"Bash","input":{"command":"swift test --filter ParserTests 2>&1 | tail -20","description":"Run the parser tests"},"title":"Claude wants to run the parser tests","conversationId":"s2"}"#,
        #"{"seq":67,"ts":T,"type":"dialogue_state","used":4,"limit":12,"paused":false,"openQuestions":1,"leadInbox":0}"#,
        #"{"seq":68,"ts":T,"type":"task","taskId":"t-c3","worker":"qwen-9b","state":"awaiting_swap","prompt":"Fuzz the lexer with random input for a minute; report any crash with its input.","by":"lead","effort":"off","profile":"test","conversationId":"s2"}"#,
        #"{"seq":69,"ts":T,"type":"dialogue","id":"e-77","kind":"ESCALATE","taskId":"t-b2","from":"lead","to":"you","text":"Where the tests go is your call: it changes the package's layout.","replyTo":"q-77","conversationId":"s2"}"#,
        #"{"seq":70,"ts":T,"type":"plan","by":"lead","steps":[{"id":"1","text":"Give tokens their source ranges","owner":"qwen-27b","status":"in_progress","taskId":"t-a1"},{"id":"2","text":"Tests for the error cases","owner":"qwen-9b","status":"in_progress","taskId":"t-b2"},{"id":"3","text":"Fuzz the lexer","owner":"qwen-9b","status":"in_progress","taskId":"t-c3"},{"id":"4","text":"Run the parser tests","owner":"lead","status":"in_progress","note":"Waiting for your approval to run swift test"},{"id":"5","text":"Review both diffs and report back","owner":"lead","status":"pending"}],"conversationId":"s2"}"#,
        // Claude's and a worker's edits (the explorer marks them), and two side chats: one answered, one answering.
        #"{"seq":71,"ts":T,"type":"task_progress","taskId":"t-a1","worker":"qwen-27b","toolUses":[{"name":"Edit","input":{"file_path":"/home/you/projects/parser/Sources/Parser/Lexer.swift","old_string":"…"}}],"conversationId":"s2"}"#,
        #"{"seq":72,"ts":T,"type":"assistant","turn":2,"text":"","toolUses":[{"id":"u8","name":"Read","input":{"file_path":"/home/you/projects/parser/Sources/Parser/Token.swift"}},{"id":"u9","name":"Edit","input":{"file_path":"/home/you/projects/parser/Sources/Parser/Token.swift","old_string":"struct Token: Equatable {\n    let kind: Kind\n    let text: String\n}","new_string":"struct Token: Equatable {\n    let kind: Kind\n    let text: String\n    /// Where it is in the source.\n    let range: Range<String.Index>\n}"}}],"conversationId":"s2"}"#,
        #"{"seq":73,"ts":T,"type":"side_chat","chatId":"sc-1","state":"answering","title":"Why does scanString re-enter Start?","model":"haiku","by":"mac","about":{"kind":"file","path":"/home/you/projects/parser/Sources/Parser/Lexer.swift","start":42,"end":58},"activity":"Reading the conversation","conversationId":"s2"}"#,
        #"{"seq":74,"ts":T,"type":"side_message","chatId":"sc-1","id":"m-1","role":"user","text":"Why does scanString re-enter Start instead of returning a token?","by":"mac","conversationId":"s2"}"#,
        #"{"seq":75,"ts":T,"type":"side_message","chatId":"sc-1","id":"msg_1","role":"assistant","text":"Because the closing quote is only *consumed* there: `scanString` returns to `Start` so the next character is scanned fresh, and the token itself is emitted by `emit(.string)` on line 57, just before the state change.\n\nIf it returned the token directly, an escape at the very end (`\\\\\"`) would end the string one character early.","conversationId":"s2"}"#,
        #"{"seq":76,"ts":T,"type":"side_chat","chatId":"sc-1","state":"idle","title":"Why does scanString re-enter Start?","model":"haiku","by":"mac","forked":"before_turn","conversationId":"s2"}"#,
        #"{"seq":77,"ts":T,"type":"side_chat","chatId":"sc-2","state":"answering","title":"Is the 9B fast enough for the tests?","model":"haiku","by":"ipad","forked":"whole","activity":"Read /home/you/projects/parser/Tests/ParserTests.swift","conversationId":"s2"}"#,
        #"{"seq":78,"ts":T,"type":"side_message","chatId":"sc-2","id":"m-2","role":"user","text":"Is the 9B fast enough for the tests?","by":"ipad","conversationId":"s2"}"#,
        #"{"seq":79,"ts":T,"type":"annotation","annotation":{"id":"n-1","intent":"question","text":"why emit before the state change?","lines":[{"file":"/home/you/projects/parser/Sources/Parser/Lexer.swift","start":34,"end":34,"code":"            if c == \"\\\"\" { emit(.string); state = .start }"}],"surface":{"kind":"file","path":"/home/you/projects/parser/Sources/Parser/Lexer.swift"},"by":"ipad","ts":T,"status":"answered","answer":"So the closing quote is consumed once: `emit(.string)` records the string up to the quote, then the state goes back to `start` for the next character. Changing state first would start the next token at the quote.","answeredBy":"qwen-27b","route":"local","checked":{"claims":2,"failed":0},"ms":14000,"chatId":"sc-n1","more":"- `emit` uses `start..<index`, so the range must end before `index` moves past the quote.\n- The same order is in `case .start` for the opening quote."},"conversationId":"s2"}"#,
        #"{"seq":80,"ts":T,"type":"annotation","annotation":{"id":"n-2","intent":"question","text":"when does it go back to InString?","elements":[{"id":"Escape","label":"Escape"}],"surface":{"kind":"diagram","diagramId":"g1","version":2,"title":"Lexer states"},"by":"mac","ts":T,"status":"open","answering":"Claude"},"conversationId":"s2"}"#,
        #"{"seq":81,"ts":T,"type":"side_chat","chatId":"sc-n1","state":"idle","title":"why emit before the state change?","model":"auto","by":"ipad","about":{"kind":"file","path":"/home/you/projects/parser/Sources/Parser/Lexer.swift","start":34,"end":34},"annotationId":"n-1","conversationId":"s2"}"#,
        #"{"seq":82,"ts":T,"type":"side_message","chatId":"sc-n1","id":"n1-q","role":"user","text":"why emit before the state change?","by":"ipad","fromNote":true,"conversationId":"s2"}"#,
        #"{"seq":83,"ts":T,"type":"side_message","chatId":"sc-n1","id":"n1-a","role":"assistant","text":"So the closing quote is consumed once.","model":"qwen-27b","local":true,"fromNote":true,"conversationId":"s2"}"#,
        #"{"seq":84,"ts":T,"type":"side_message","chatId":"sc-n1","id":"n1-r1","role":"user","text":"and in case .start, same order?","by":"ipad","conversationId":"s2"}"#,
        #"{"seq":85,"ts":T,"type":"side_message","chatId":"sc-n1","id":"n1-r1a","role":"assistant","text":"Yes for the opening quote: the state changes to `inString` and the quote is skipped, so the string token starts after it. Nothing is emitted there; the token is emitted once, at the closing quote.","model":"qwen-27b","local":true,"checked":{"claims":1,"failed":0},"ms":9000,"conversationId":"s2"}"#,
        #"{"seq":86,"ts":T,"type":"annotation","annotation":{"id":"n-3","intent":"question","text":"why save start before step?","lines":[{"file":"/home/you/projects/parser/Sources/Parser/Lexer.swift","start":21,"end":21,"code":"            start = index"}],"surface":{"kind":"file","path":"/home/you/projects/parser/Sources/Parser/Lexer.swift"},"by":"mac","ts":T,"status":"open","answering":"Claude","escalated":"you asked Claude","chatId":"sc-n3"},"conversationId":"s2"}"#,
        #"{"seq":87,"ts":T,"type":"side_chat","chatId":"sc-n3","state":"answering","title":"why save start before step?","model":"sonnet","by":"mac","about":{"kind":"file","path":"/home/you/projects/parser/Sources/Parser/Lexer.swift","start":21,"end":21},"annotationId":"n-3","activity":"Reading Lexer.swift","forked":"whole","conversationId":"s2"}"#,
        #"{"seq":88,"ts":T,"type":"side_message","chatId":"sc-n3","id":"n3-q","role":"user","text":"why save start before step?","by":"mac","fromNote":true,"conversationId":"s2"}"#,
        #"{"seq":89,"ts":T,"type":"side_delta","chatId":"sc-n3","text":"Because `step` moves `index` past the character it reads, so the token's start has to be saved first: `emit` later uses `start..<index`.","conversationId":"s2"}"#,
        #"{"seq":90,"ts":T,"type":"conversation_import","from":{"sessionId":"d-7","name":"Lexer state machine","cwd":"/home/you/projects/parser","where":"desktop","status":"idle","live":true},"forked":true,"messages":[{"uuid":"i1","role":"user","text":"How does the lexer track strings?"},{"uuid":"i2","role":"assistant","text":"With a small state machine: `start`, `inString` and `escape`.","tools":["Read Sources/Parser/Lexer.swift"]}],"conversationId":"s3"}"#,
        // Claude asking to leave plan mode with its plan (Plan mode).
        #"{"seq":91,"ts":T,"type":"approval_request","id":"ap-plan","turn":2,"tool":"ExitPlanMode","input":{"plan":"**Error recovery in the lexer**\n\n1. **Report, don't stop**: `Lexer.scan()` collects errors with their ranges instead of throwing at the first.\n2. **Unterminated strings** end at the line break, as an error token.\n3. **Bad escapes** keep the character and add an error.\n4. Tests in `ParserErrorTests.swift` for each case.\n\nNothing changes outside `Sources/Parser`."},"plan":"**Error recovery in the lexer**\n\n1. **Report, don't stop**: `Lexer.scan()` collects errors with their ranges instead of throwing at the first.\n2. **Unterminated strings** end at the line break, as an error token.\n3. **Bad escapes** keep the character and add an error.\n4. Tests in `ParserErrorTests.swift` for each case.\n\nNothing changes outside `Sources/Parser`.","conversationId":"s2"}"#,
        // Claude asking you something before it goes on (AskUserQuestion, as plan mode has it).
        #"{"seq":92,"ts":T,"type":"approval_request","id":"ap-ask","turn":2,"tool":"AskUserQuestion","input":{"questions":[{"question":"Where should the error tests live?","header":"Tests","options":[{"label":"ParserTests.swift","description":"Beside the parser's other tests"},{"label":"A new ParserErrorTests.swift","description":"The error cases on their own"}],"multiSelect":false}]},"conversationId":"s2"}"#,
    ]

    /// Claude's folder, as the explorer lists it.
    static let listings: [String: String] = [
        "/home/you/projects/parser": #"{"path":"/home/you/projects/parser","parent":"/home/you/projects","truncated":false,"repo":{"root":"/home/you/projects/parser","branch":"token-ranges"},"entries":[{"name":".github","kind":"dir","size":0,"mtime":0},{"name":"Sources","kind":"dir","size":0,"mtime":0,"git":"•"},{"name":"Tests","kind":"dir","size":0,"mtime":0,"git":"•"},{"name":"Package.swift","kind":"file","size":612,"mtime":0},{"name":"README.md","kind":"file","size":2210,"mtime":0,"git":"M"}]}"#,
        "/home/you/projects/parser/Sources": #"{"path":"/home/you/projects/parser/Sources","parent":"/home/you/projects/parser","truncated":false,"entries":[{"name":"Parser","kind":"dir","size":0,"mtime":0,"git":"•"}]}"#,
        "/home/you/projects/parser/Sources/Parser": #"{"path":"/home/you/projects/parser/Sources/Parser","parent":"/home/you/projects/parser/Sources","truncated":false,"entries":[{"name":"Lexer.swift","kind":"file","size":8120,"mtime":0,"git":"M"},{"name":"Parser.swift","kind":"file","size":12040,"mtime":0},{"name":"Token.swift","kind":"file","size":1630,"mtime":0,"git":"M"},{"name":"OldScanner.swift","kind":"file","size":3100,"mtime":0,"git":"D"}]}"#,
        "/home/you/projects/parser/Tests": #"{"path":"/home/you/projects/parser/Tests","parent":"/home/you/projects/parser","truncated":false,"entries":[{"name":"ParserTests.swift","kind":"file","size":4410,"mtime":0},{"name":"ParserErrorTests.swift","kind":"file","size":980,"mtime":0,"git":"?"}]}"#,
    ]

    /// The files the sample conversation is about, as the hub would read them (a debug run with no hub reads these).
    static func demoFile(_ path: String) -> FsFile? {
        guard let text = files[path] else { return nil }
        let json: [String: Any] = ["path": path, "size": text.utf8.count, "mtime": 1_760_000_000_000, "binary": false, "truncated": false,
                                   "text": text, "git": "M", "changed": [33, 34], "removedAfter": []]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? JSONDecoder().decode(FsFile.self, from: data)
    }

    static let files: [String: String] = [
        "/home/you/projects/parser/Sources/Parser/Lexer.swift": #"""
        import Foundation

        /// Splits source text into tokens, each with the range it came from.
        struct Lexer {
            enum State { case start, inString, escape }

            let source: String
            private(set) var index: String.Index
            private(set) var tokens: [Token] = []
            private var state = State.start
            private var start: String.Index

            init(_ source: String) {
                self.source = source
                index = source.startIndex
                start = source.startIndex
            }

            mutating func scan() -> [Token] {
                while index < source.endIndex {
                    start = index
                    step(source[index])
                }
                return tokens
            }

            private mutating func step(_ c: Character) {
                switch state {
                case .start:
                    if c == "\"" { state = .inString }
                    index = source.index(after: index)
                case .inString:
                    if c == "\\" { state = .escape }
                    if c == "\"" { emit(.string); state = .start }
                    index = source.index(after: index)
                case .escape:
                    // The escaped character stays in the string.
                    state = .inString
                    index = source.index(after: index)
                }
            }

            private mutating func emit(_ kind: Token.Kind) {
                tokens.append(Token(kind: kind, range: start..<index))
            }
        }

        """#,
    ]

    /// The user's devices, as the hub lists them: the Mac with Duet open, the iPhone away (Send to iPad).
    static let devices: [DeviceInfo] = [
        DeviceInfo(device: "mac", online: true, lastSeen: t0 * 1000, kind: "mac"),
        DeviceInfo(device: "ipad", online: true, lastSeen: t0 * 1000, kind: "ipad"),
        DeviceInfo(device: "iphone", online: false, lastSeen: (t0 - 3 * 3600) * 1000, kind: "iphone"),
    ]

    /// Claude Code sessions running outside Duet on the hub machine, as the hub lists them (a debug run with no hub shows these).
    static let outside: [OutsideSession] = {
        let json = #"[{"sessionId":"d-1","name":"Chip findings","cwd":"/home/you/projects/chips","where":"desktop","status":"busy","live":true,"updatedAt":T},{"sessionId":"d-2","name":"Fix the flaky lexer test","cwd":"/home/you/projects/parser","where":"terminal","status":"idle","live":true,"updatedAt":T},{"sessionId":"d-3","name":"Nightly benchmark","cwd":"/home/you/bench","where":"background","status":"waiting","live":true},{"sessionId":"d-4","name":"Docs site cleanup","cwd":"/home/you/docs-site","where":"desktop","status":"ended","live":false,"endedAt":T}]"#
            .replacingOccurrences(of: ":T", with: ":\(Int(t0))")
        return (try? JSONDecoder().decode([OutsideSession].self, from: Data(json.utf8))) ?? []
    }()

    /// What one of them said, as following it gets it.
    static let outsideMessages: [String: [OutsideMessage]] = [
        "d-1": [
            OutsideMessage(json: #"{"uuid":"o1","role":"user","text":"Which of the RTX chips throttle first under a long run?"}"#),
            OutsideMessage(json: #"{"uuid":"o2","role":"assistant","text":"","tools":["Bash nvidia-smi -q -d PERFORMANCE","Read bench/results.jsonl"]}"#),
            OutsideMessage(json: #"{"uuid":"o3","role":"assistant","text":"The 3060 throttles first: it hits its power limit after about 6 minutes at full load, and its clocks drop 12%. The R9700 holds its clocks for the whole run."}"#),
            OutsideMessage(json: #"{"uuid":"o4","role":"user","text":"Write that up in findings.md"}"#),
            OutsideMessage(json: #"{"uuid":"o5","role":"assistant","text":"","tools":["Edit findings.md"]}"#),
        ].compactMap { $0 },
    ]

    /// What the sample tasks changed, as the hub would send their diffs (a debug run with no hub reads these).
    static let diffs: [String: String] = [
        "t-d4": #"""
        diff --git a/Sources/Parser/Lexer.swift b/Sources/Parser/Lexer.swift
        index 3f2a1c4..8b9d0e2 100644
        --- a/Sources/Parser/Lexer.swift
        +++ b/Sources/Parser/Lexer.swift
        @@ -43,6 +43,6 @@ struct Lexer {
             private mutating func emit(_ kind: Token.Kind) {
        -        tokens.append(Token(kind: kind, text: source[start..<index]))
        +        tokens.append(Token(kind: kind, lexeme: source[start..<index]))
             }
         }
        diff --git a/Sources/Parser/Token.swift b/Sources/Parser/Token.swift
        index 1b2c3d4..5e6f7a8 100644
        --- a/Sources/Parser/Token.swift
        +++ b/Sources/Parser/Token.swift
        @@ -3,6 +3,6 @@
         struct Token: Equatable {
             let kind: Kind
        -    let text: Substring
        +    let lexeme: Substring
             let range: Range<String.Index>
         }
        diff --git a/Tests/ParserTests/LexerTests.swift b/Tests/ParserTests/LexerTests.swift
        index 9a8b7c6..1d2e3f4 100644
        --- a/Tests/ParserTests/LexerTests.swift
        +++ b/Tests/ParserTests/LexerTests.swift
        @@ -10,7 +10,7 @@ struct LexerTests {
             @Test func string() {
                 let t = Lexer("\"x\"").scan()
        -        #expect(t[0].text == "\"x\"")
        +        #expect(t[0].lexeme == "\"x\"")
             }
        """#,
    ]

    /// `showing`: what the regular layout opens on; `selecting`: the conversation the iPhone's Chat shows (nil: live);
    /// `explorer`: the sidebar shows Claude's folder.
    static func model(live: Bool = false, showing: Destination = .lead, selecting: String? = nil, explorer: Bool = false) -> AppModel {
        let m = AppModel()
        var seq = 0
        for line in lines {
            let json = line.replacingOccurrences(of: #""ts":T"#, with: #""ts":\#(Int(t0))"#)
            if case .event(let e) = try? JSONDecoder().decode(ServerFrame.self, from: Data(json.utf8)) {
                m.store.apply(e)
                seq = e.seq
            }
        }
        if live {
            let delta = #"{"seq":\#(seq + 1),"ts":\#(Int(t0)),"type":"text_delta","turn":2,"text":"While the tests run: the lexer change touches `scanString` and `scanNumber`; both now record `start` before advancing…","conversationId":"s2"}"#
            if case .event(let e) = try? JSONDecoder().decode(ServerFrame.self, from: Data(delta.utf8)) { m.store.apply(e) }
            m.store.flushStreaming()
        }
        m.refreshConversationList()
        m.destination = showing
        if let selecting { m.selectedConversation = selecting }
        if explorer {
            let decoded = listings.compactMapValues { try? JSONDecoder().decode(FsListing.self, from: Data($0.utf8)) }
            m.explorer.preview(root: "/home/you/projects/parser", listings: decoded,
                               expanded: ["/home/you/projects/parser/Sources", "/home/you/projects/parser/Sources/Parser", "/home/you/projects/parser/Tests"],
                               selected: "/home/you/projects/parser/Sources/Parser/Lexer.swift")
            m.sidebarMode = .explorer
        }
        return m
    }
}

#if os(macOS)
#Preview("Mac · main window", traits: .fixedLayout(width: 1360, height: 820)) {
    RegularRoot().environment(PreviewData.model()).environment(\.density, .dense)
}

#Preview("Mac · past conversation", traits: .fixedLayout(width: 1360, height: 820)) {
    RegularRoot().environment(PreviewData.model(showing: .conversation("s1"))).environment(\.density, .dense)
}

#Preview("Mac · menu bar panel") {
    MenuBarPanel().environment(PreviewData.model())
}
#endif

#if os(iOS)
#Preview("iPhone · Now") {
    PhoneRoot().environment(PreviewData.model())
}

#Preview("iPhone · Chat") {
    let m = PreviewData.model(live: true)
    m.phoneTab = .chat
    return PhoneRoot().environment(m)
}

#Preview("iPhone · Chat (read-only)") {
    let m = PreviewData.model(selecting: "s1")
    m.phoneTab = .chat
    return PhoneRoot().environment(m)
}

#Preview("iPad · landscape", traits: .landscapeLeft) {
    RegularRoot().environment(PreviewData.model()).environment(\.density, .regular)
}
#endif

#Preview("Conversation cards") {
    SupportRail(conversationId: "s1")
        .environment(PreviewData.model(showing: .conversation("s1")))
        .frame(width: 320, height: 760)
}

#Preview("Conversation cards · live") {
    SupportRail(conversationId: "s2")
        .environment(PreviewData.model())
        .frame(width: 320, height: 760)
}

#Preview("Explorer", traits: .fixedLayout(width: 320, height: 640)) {
    NavigationStack { ExplorerSidebar() }
        .environment(PreviewData.model(explorer: true))
}

#Preview("Side chat", traits: .fixedLayout(width: 420, height: 600)) {
    SideChatView(ref: SideChatRef(chatId: "sc-1"))
        .environment(PreviewData.model())
}

#Preview("Side chat · answering", traits: .fixedLayout(width: 420, height: 420)) {
    SideChatView(ref: SideChatRef(chatId: "sc-2"))
        .environment(PreviewData.model())
}

#Preview("Talk mode", traits: .fixedLayout(width: 640, height: 330)) {
    let listening = PreviewData.model(), working = PreviewData.model(), speaking = PreviewData.model()
    listening.voice.preview(.listening, said: "Have the small worker rename", guess: "the helper in fleet")
    working.voice.preview(.working)
    speaking.voice.preview(.speaking, caption: "It picks the idle worker with the shortest queue, and prefers the nine B model for small tasks.")
    return VStack(spacing: 1) {
        TalkPanel().environment(listening)
        TalkPanel().environment(working)
        TalkPanel().environment(speaking)
        Composer().environment(PreviewData.model())
    }
    .background(.separator)
}

#Preview("File · a note answered in place", traits: .fixedLayout(width: 700, height: 360)) {
    let text = "name: verify\non: pull_request\njobs:\n  verify:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: familiar-ai/action@v1\n        with:\n          version: 0.1.0-dev\n          strict: true"
    let marks: [Int: LineMark] = [
        9: LineMark(ids: ["n1"], state: "answered", cards: [NoteCard(id: "n1", question: "What does this mean?", answer: FileViewer.gist("Let me check.\n\n`version: 0.1.0-dev` says which release of the **familiar-ai** binary CI downloads and runs. It's a pinned version number, not a setting that changes how verify behaves."))]),
        10: LineMark(ids: ["n2"], state: "open", cards: [NoteCard(id: "n2", question: "Do we need strict here?", answer: nil)]),
    ]
    return DiagramWebView(page: DiagramPage(), document: .code(path: "/p/verify.yml", text: text, changed: [], removedAfter: [], marks: marks))
}

#Preview("Plan") {
    ScrollView { PlanList(conversationId: "s2").padding() }
        .environment(PreviewData.model())
        .frame(width: 360, height: 640)
}

#Preview("Decision cards") {
    ScrollView {
        AttentionList().padding()
    }
    .environment(PreviewData.model())
    .frame(width: 420, height: 760)
}
#endif

#if DEBUG
extension OutsideMessage {
    /// A sample message from its JSON, for test runs.
    init?(json: String) {
        guard let m = try? JSONDecoder().decode(OutsideMessage.self, from: Data(json.utf8)) else { return nil }
        self = m
    }
}
#endif
