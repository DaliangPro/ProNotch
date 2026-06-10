import Foundation
import SwiftUI

struct ChatMessage: Identifiable, Equatable {
    enum Role: String {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    var content: String
}

/// AI 对话数据源：OpenAI 兼容接口 + SSE 流式输出。
/// 会话仅存内存（面板收起保留，应用重启清空）；设置持久化到 UserDefaults。
@MainActor
final class ChatStore: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published private(set) var isStreaming = false
    @Published var errorText: String?

    @Published private(set) var baseURL: String
    @Published private(set) var apiKey: String
    @Published private(set) var model: String

    private var streamTask: Task<Void, Never>?

    var isConfigured: Bool {
        !baseURL.isEmpty && !apiKey.isEmpty && !model.isEmpty
    }

    init() {
        let defaults = UserDefaults.standard
        baseURL = defaults.string(forKey: "chatBaseURL") ?? ""
        apiKey = defaults.string(forKey: "chatAPIKey") ?? ""
        model = defaults.string(forKey: "chatModel") ?? ""
    }

    func saveSettings(baseURL: String, apiKey: String, model: String) {
        self.baseURL = baseURL.trimmingCharacters(in: .whitespaces)
        self.apiKey = apiKey.trimmingCharacters(in: .whitespaces)
        self.model = model.trimmingCharacters(in: .whitespaces)
        let defaults = UserDefaults.standard
        defaults.set(self.baseURL, forKey: "chatBaseURL")
        defaults.set(self.apiKey, forKey: "chatAPIKey")
        defaults.set(self.model, forKey: "chatModel")
        print("[NotchHub] 已保存 AI 设置，端点: \((try? endpointURL())?.absoluteString ?? "无效")")
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming, isConfigured else { return }
        errorText = nil
        messages.append(ChatMessage(role: .user, content: trimmed))
        let payload = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        messages.append(ChatMessage(role: .assistant, content: ""))
        isStreaming = true
        streamTask = Task { [weak self] in
            await self?.stream(payload: payload)
        }
    }

    func stopStreaming() {
        streamTask?.cancel()
    }

    func clearConversation() {
        stopStreaming()
        messages = []
        errorText = nil
    }

    // MARK: - 私有

    /// 端点规范化：已带 /chat/completions 直接用；带 /v1 补 /chat/completions；
    /// 否则补 /v1/chat/completions
    private func endpointURL() throws -> URL {
        var raw = baseURL.trimmingCharacters(in: .whitespaces)
        while raw.hasSuffix("/") { raw.removeLast() }
        if !raw.hasSuffix("/chat/completions") {
            raw += raw.hasSuffix("/v1") ? "/chat/completions" : "/v1/chat/completions"
        }
        guard let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else {
            throw NSError(domain: "NotchHub", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "API 地址无效: \(raw)"])
        }
        return url
    }

    private func stream(payload: [[String: String]]) async {
        defer {
            isStreaming = false
            streamTask = nil
        }
        do {
            var request = URLRequest(url: try endpointURL())
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "messages": payload,
                "stream": true,
            ])

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > 4096 { break }
                }
                let detail = String(data: data, encoding: .utf8) ?? ""
                throw NSError(domain: "NotchHub", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey:
                                  "HTTP \(http.statusCode) \(detail.prefix(200))"])
            }

            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if json == "[DONE]" { break }
                guard let data = json.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = object["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any],
                      let content = delta["content"] as? String,
                      !content.isEmpty else { continue }
                appendToLastAssistant(content)
            }
            print("[NotchHub] AI 回复完成（\(messages.last?.content.count ?? 0) 字符）")
        } catch is CancellationError {
            print("[NotchHub] AI 回复已停止")
        } catch let error as URLError where error.code == .cancelled {
            print("[NotchHub] AI 回复已停止")
        } catch {
            errorText = error.localizedDescription
            // 失败时移除空的占位回复
            if let last = messages.last, last.role == .assistant, last.content.isEmpty {
                messages.removeLast()
            }
            print("[NotchHub] AI 请求失败: \(error.localizedDescription)")
        }
    }

    private func appendToLastAssistant(_ chunk: String) {
        guard let last = messages.indices.last,
              messages[last].role == .assistant else { return }
        messages[last].content += chunk
    }
}
