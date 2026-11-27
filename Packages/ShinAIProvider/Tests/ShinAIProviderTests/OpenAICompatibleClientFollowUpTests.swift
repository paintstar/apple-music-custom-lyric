import Foundation
import Testing
@testable import ShinAIProvider

extension OpenAICompatibleClientTests {
    @Test("整句追问发送原解析与最近三轮，返回普通文本")
    func lineFollowUpIncludesRecentTurns() async throws {
        var requests: [[[String: String]]] = []
        MockAIURLProtocol.handler = { request in
            let data = try #require(MockAIURLProtocol.bodyData(from: request))
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(body["response_format"] == nil)
            requests.append(try #require(body["messages"] as? [[String: String]]))
            let reply = "第\(requests.count)次模拟回答"
            let envelope = ["choices": [["message": ["content": reply]]]]
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (response, try JSONSerialization.data(withJSONObject: envelope))
        }

        let client = MockAIURLProtocol.makeClient()
        let configuration = AIConfiguration(preset: .deepSeek)
        let context = AILineContext(previousLine: "雨点离开铁轨", nextLine: "街角为我等候", sourceLanguage: "zh")
        let analysis = AILineExplanation(grammarSummary: "纸船是句中的主语", keyExpressions: ["描绘光线"])
        var history: [AILineFollowUpTurn] = []
        for index in 1...5 {
            let question = "第\(index)个虚构问题"
            let answer = try await client.followUpLine(
                AILineFollowUpRequest(
                    lineText: "纸船载走最后一束光", context: context,
                    analysis: analysis, history: history, question: question
                ),
                configuration: configuration,
                apiKey: "test-key"
            )
            #expect(answer == "第\(index)次模拟回答")
            history.append(AILineFollowUpTurn(question: question, answer: answer))
        }

        let second = requests[1]
        #expect(second.map { $0["role"] } == ["system", "user", "assistant", "user", "assistant", "user"])
        #expect(second[1]["content"]?.contains("纸船载走最后一束光") == true)
        #expect(second[1]["content"]?.contains("雨点离开铁轨") == true)
        #expect(second[1]["content"]?.contains("街角为我等候") == true)
        #expect(second[2]["content"]?.contains("纸船是句中的主语") == true)
        #expect(second.dropFirst(3).compactMap { $0["content"] } == [
            "第1个虚构问题", "第1次模拟回答", "第2个虚构问题"
        ])
        #expect(requests[4].dropFirst(3).compactMap { $0["content"] } == [
            "第2个虚构问题", "第2次模拟回答",
            "第3个虚构问题", "第3次模拟回答",
            "第4个虚构问题", "第4次模拟回答",
            "第5个虚构问题"
        ])
    }
}
