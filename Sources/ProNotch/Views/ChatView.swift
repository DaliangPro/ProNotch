import SwiftUI

/// AI 闪问：未配置时显示设置表单；配置后为消息列表 + 输入框，流式输出
struct ChatView: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var store: ChatStore

    @FocusState private var inputFocused: Bool

    private let edgeInset: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.showSettings || !store.isConfigured {
                ChatSettingsForm(showSettings: $store.showSettings,
                                 onFocusChange: { vm.keyboardHold = $0 })
            } else {
                if store.messages.isEmpty, store.errorText == nil {
                    // 空状态提示在整个消息区居中
                    Text("想和我聊点什么？")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    messageList
                }
                inputBar
            }
        }
        .onAppear { store.checkConnectivity() }
        .onDisappear { vm.keyboardHold = false }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    ForEach(store.messages) { message in
                        MessageBubble(message: message,
                                      streaming: store.isStreaming
                                          && message.id == store.messages.last?.id,
                                      searching: store.isSearching)
                    }
                    if let error = store.errorText {
                        Text(error)
                            .font(.system(size: 10))
                            .foregroundColor(.red.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, edgeInset)
            }
            .onChange(of: store.messages.last?.content) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Button {
                store.webSearchEnabled.toggle()
            } label: {
                Image(systemName: "globe")
                    .font(.system(size: 13))
                    .foregroundColor(store.webSearchEnabled ? .cyan : .white.opacity(0.35))
            }
            .buttonStyle(.plain)
            .help(store.webSearchEnabled
                ? "联网搜索已开启：先搜索再回答（点击关闭）"
                : "联网搜索已关闭（点击开启）")
            TextField("", text: $store.draftMessage,
                      prompt: Text("输入问题，回车发送")
                          .foregroundColor(.white.opacity(0.3)))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .focused($inputFocused)
                .onSubmit { sendDraft() }
                .onChange(of: inputFocused) { vm.keyboardHold = $0 }
            if store.isStreaming {
                Button {
                    store.stopStreaming()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("停止")
            } else {
                Button {
                    sendDraft()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(store.draftMessage.isEmpty
                            ? .white.opacity(0.25) : .white.opacity(0.8))
                }
                .buttonStyle(.plain)
                .disabled(store.draftMessage.isEmpty)
                .help("发送")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
        .padding(.horizontal, edgeInset)
    }

    private func sendDraft() {
        let text = store.draftMessage
        store.draftMessage = ""
        store.send(text)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let streaming: Bool
    let searching: Bool

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 80) }
            Group {
                if message.content.isEmpty && streaming {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        if searching {
                            Text("正在联网搜索…")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                    .padding(4)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        if let count = message.searchResultCount {
                            HStack(spacing: 3) {
                                Image(systemName: "globe")
                                    .font(.system(size: 8))
                                Text("已参考 \(count) 条搜索结果")
                                    .font(.system(size: 9))
                            }
                            .foregroundColor(.cyan.opacity(0.75))
                        }
                        if message.role == .assistant {
                            // AI 回复按 Markdown 排版；用户消息保持纯文本
                            MarkdownMessageView(text: message.content)
                        } else {
                            Text(message.content)
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.9))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(message.role == .user ? 0.16 : 0.06)))
            if message.role == .assistant { Spacer(minLength: 80) }
        }
        .frame(maxWidth: .infinity,
               alignment: message.role == .user ? .trailing : .leading)
        .id(message.id)
    }
}

/// API 设置表单：兼容 OpenAI /v1/chat/completions 格式。
/// 面板内与设置窗口两处复用；聚焦回调由调用方决定（面板内用于暂停自动收起）
struct ChatSettingsForm: View {
    @EnvironmentObject var store: ChatStore
    @Binding var showSettings: Bool
    var onFocusChange: ((Bool) -> Void)? = nil

    @State private var showModelList = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case url, key, model, searchKey
    }

    private var canFetchModels: Bool {
        !store.draftBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !store.draftAPIKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !store.fetchingModels
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingField("API 地址", text: $store.draftBaseURL,
                         placeholder: "如 https://api.deepseek.com", field: .url)
            HStack(spacing: 6) {
                Text("API Key")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 50, alignment: .leading)
                SecureField("", text: $store.draftAPIKey,
                            prompt: Text("sk-…").foregroundColor(.white.opacity(0.3)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .focused($focusedField, equals: .key)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
            }
            HStack(spacing: 6) {
                Text("模型")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 50, alignment: .leading)
                // 输入框与下拉选择二合一：箭头长在输入框右端内部，
                // 列表不走系统弹窗（在无边框面板里定位会飘），改为表单内展开
                HStack(spacing: 4) {
                    TextField("", text: $store.draftModel,
                              prompt: Text(store.availableModels.isEmpty
                                      ? "如 deepseek-chat，或先点「获取模型」"
                                      : "选择或输入模型名")
                                  .foregroundColor(.white.opacity(0.3)))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                        .focused($focusedField, equals: .model)
                    if !store.availableModels.isEmpty {
                        Button {
                            withAnimation(.easeOut(duration: 0.12)) {
                                showModelList.toggle()
                            }
                        } label: {
                            Image(systemName: showModelList ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .help("从已获取的 \(store.availableModels.count) 个模型中选择")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                // 下拉列表用 overlay 悬浮在表单上层：贴字段下沿弹出、
                // 盖住下方内容，不参与布局（不会把表单顶开）
                .overlay(alignment: .topLeading) {
                    if showModelList, !store.availableModels.isEmpty {
                        modelDropdown
                            .offset(y: 27)
                    }
                }
                Button {
                    store.fetchModels()
                } label: {
                    Group {
                        if store.fetchingModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("获取模型").font(.system(size: 10))
                        }
                    }
                    .foregroundColor(canFetchModels ? .white.opacity(0.8) : .white.opacity(0.3))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(canFetchModels ? 0.12 : 0.05)))
                }
                .buttonStyle(.plain)
                .disabled(!canFetchModels)
                .help("从服务端读取可用模型列表（需先填地址和 Key）")
            }
            // 保证悬浮下拉盖在后续兄弟行（提示与保存按钮）之上
            .zIndex(10)

            HStack(spacing: 6) {
                Text("搜索 Key")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 50, alignment: .leading)
                SecureField("", text: $store.draftTavilyKey,
                            prompt: Text("选填：Tavily Key；不填则用内置免费搜索（稳定性一般）")
                                .foregroundColor(.white.opacity(0.3)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .focused($focusedField, equals: .searchKey)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
            }

            if let fetchError = store.fetchError {
                Text(fetchError)
                    .font(.system(size: 9))
                    .foregroundColor(.red.opacity(0.8))
                    .lineLimit(2)
            }

            HStack {
                Text("兼容 OpenAI /v1/chat/completions 格式；地址填到域名或 /v1 即可")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.3))
                Spacer()
                Button("保存") { save() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(canSave ? .white : .white.opacity(0.3))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(canSave ? 0.18 : 0.06)))
                    .disabled(!canSave)
            }
        }
        .padding(.horizontal, edgeInset)
        .onChange(of: focusedField) { onFocusChange?($0 != nil) }
        .onDisappear { onFocusChange?(false) }
    }

    private let edgeInset: CGFloat = 14

    private var canSave: Bool {
        !store.draftBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !store.draftAPIKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !store.draftModel.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        store.saveSettings()
        showSettings = false
    }

    /// 悬浮下拉：不透明深色背景 + 描边 + 阴影，视觉上明确是覆盖层
    private var modelDropdown: some View {
        let rowHeight: CGFloat = 24
        let height = min(CGFloat(store.availableModels.count) * rowHeight + 6, 130)
        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(store.availableModels, id: \.self) { name in
                    ModelOptionRow(name: name,
                                   isSelected: name == store.draftModel) {
                        store.draftModel = name
                        withAnimation(.easeIn(duration: 0.1)) {
                            showModelList = false
                        }
                    }
                }
            }
            .padding(.vertical, 3)
        }
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.11, green: 0.11, blue: 0.12)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }

    private struct ModelOptionRow: View {
        let name: String
        let isSelected: Bool
        let action: () -> Void

        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack {
                    Text(name)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.white.opacity(hovering ? 0.12 : 0))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }

    private func settingField(_ label: String, text: Binding<String>,
                              placeholder: String, field: Field) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
                .frame(width: 50, alignment: .leading)
            TextField("", text: text,
                      prompt: Text(placeholder).foregroundColor(.white.opacity(0.3)))
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.white)
                .focused($focusedField, equals: field)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
        }
    }
}
