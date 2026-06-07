import XCTest
@testable import AgentDeckApp

final class AskUserQuestionTests: XCTestCase {
    func testAnsweredQuestionToolRecordRoundTripsSelections() throws {
        let question = AskUserQuestion(questions: [
            .init(
                header: "测试",
                question: "接下来测试什么？",
                multiSelect: true,
                options: [.init(label: "Diff"), .init(label: "MCP")]
            )
        ])
        var record = QuestionToolRecord(question: question)
        record.answer([["Diff", "MCP"]])

        let data = try JSONEncoder().encode(record)
        let restored = try JSONDecoder().decode(QuestionToolRecord.self, from: data)

        XCTAssertEqual(restored.resolution, .answered([["Diff", "MCP"]]))
        XCTAssertFalse(restored.isPending)
        XCTAssertEqual(restored.detailLines, [
            "Question：接下来测试什么？",
            "Choose：Diff / MCP"
        ])
    }

    func testIsAskUserQuestionToleratesWritingVariants() {
        XCTAssertTrue(AskUserQuestionParser.isAskUserQuestion(toolName: "AskUserQuestion"))
        XCTAssertTrue(AskUserQuestionParser.isAskUserQuestion(toolName: "ask_user_question"))
        XCTAssertTrue(AskUserQuestionParser.isAskUserQuestion(toolName: "askuserquestion"))
        XCTAssertFalse(AskUserQuestionParser.isAskUserQuestion(toolName: "Read"))
    }

    func testParseObjectOptionsAndMultiSelect() {
        let json = #"""
        {"questions":[
          {"header":"鉴权","question":"用哪种登录？","multiSelect":false,
           "options":[{"label":"OAuth","description":"浏览器登录"},{"label":"API Key"}]},
          {"header":"功能","question":"开启哪些？","multiSelect":true,
           "options":[{"label":"A"},{"label":"B"}]}
        ]}
        """#
        let parsed = AskUserQuestionParser.parse(inputJSON: json)
        XCTAssertEqual(parsed?.questions.count, 2)
        XCTAssertEqual(parsed?.questions.first?.title, "用哪种登录？")
        XCTAssertEqual(parsed?.questions.first?.multiSelect, false)
        XCTAssertEqual(parsed?.questions.first?.options.first?.description, "浏览器登录")
        XCTAssertEqual(parsed?.questions.last?.multiSelect, true)
        XCTAssertEqual(parsed?.questions.last?.options.map(\.label), ["A", "B"])
    }

    func testParseFallsBackToHeaderWhenQuestionMissingAndBareStringOptions() {
        let json = #"{"questions":[{"header":"模式","options":["快","慢"]}]}"#
        let parsed = AskUserQuestionParser.parse(inputJSON: json)
        XCTAssertEqual(parsed?.questions.first?.title, "模式") // question 缺失时回退 header
        XCTAssertEqual(parsed?.questions.first?.options.map(\.label), ["快", "慢"])
    }

    func testParseRejectsMalformedOrEmpty() {
        XCTAssertNil(AskUserQuestionParser.parse(inputJSON: "not json"))
        XCTAssertNil(AskUserQuestionParser.parse(inputJSON: #"{"questions":[]}"#))
        // 无选项的问题被丢弃；全丢弃则整体 nil。
        XCTAssertNil(AskUserQuestionParser.parse(inputJSON: #"{"questions":[{"header":"x","options":[]}]}"#))
    }

    func testParseFlatOpenCodeShapeWithMessageAndChoices() {
        // opencode 等的扁平单问形态：message + choices（而非 Claude 的 questions/options 嵌套）。
        let json = #"{"message":"选哪个分支？","choices":["main","dev"],"multiple":true}"#
        let parsed = AskUserQuestionParser.parse(inputJSON: json)
        XCTAssertEqual(parsed?.questions.count, 1)
        XCTAssertEqual(parsed?.questions.first?.title, "选哪个分支？")
        XCTAssertEqual(parsed?.questions.first?.multiSelect, true)
        XCTAssertEqual(parsed?.questions.first?.options.map(\.label), ["main", "dev"])
    }

    func testFallbackPromptExtractsQuestionTextWhenNoOptions() {
        // 无结构化选项 → parse 为 nil，但仍能抽出问题文本给兜底提示用。
        let json = #"{"prompt":"要我继续吗？"}"#
        XCTAssertNil(AskUserQuestionParser.parse(inputJSON: json))
        XCTAssertEqual(AskUserQuestionParser.fallbackPrompt(inputJSON: json), "要我继续吗？")
    }

    func testParseOpenCodeNestedQuestionsCarriesRequestID() {
        // opencode question.asked：questions 嵌在 input 下，requestID 在顶层（回传句柄）。
        let json = #"{"type":"question","requestID":"que_9","input":{"questions":[{"question":"用哪个分支?","header":"分支","options":[{"label":"main","description":"稳定"},{"label":"dev"}],"multiple":true}]}}"#
        let parsed = AskUserQuestionParser.parse(inputJSON: json)
        XCTAssertEqual(parsed?.requestID, "que_9")
        XCTAssertEqual(parsed?.questions.first?.multiSelect, true)
        XCTAssertEqual(parsed?.questions.first?.options.map(\.label), ["main", "dev"])
        XCTAssertEqual(parsed?.questions.first?.options.first?.description, "稳定")
    }
}
