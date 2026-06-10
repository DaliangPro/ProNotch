import SwiftUI

/// 妙记页：输入即存 Obsidian 收件箱 + 今天已记列表
struct CaptureView: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var store: CaptureStore

    @FocusState private var focused: Bool
    @State private var savedFlash = false

    private let edgeInset: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 输入区：回车只换行（避免误触把半截内容存进去），点「存入」才入库。
            // 编辑器铺满整张卡片，点卡片任意位置都落在文本视图上、直接唤起光标
            ZStack(alignment: .topLeading) {
                TextEditor(text: $store.draft)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .scrollContentBackground(.hidden)
                    .frame(height: 84)
                    // 编辑器自带 5pt 文字内边距，补 7pt 凑齐卡片的 12pt
                    .padding(.horizontal, 7)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .focused($focused)
                    .onChange(of: focused) { vm.keyboardHold = $0 }
                // 自绘占位文字：比正文小一号且用细体，与正文起点对齐
                if store.draft.isEmpty {
                    Text("记下一闪而过的灵感，回车换行，写完点存入")
                        .font(.system(size: 12, weight: .light))
                        .foregroundColor(.white.opacity(0.3))
                        .allowsHitTesting(false)
                        .padding(.leading, 12)
                        .padding(.top, 10)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08)))
            .overlay(alignment: .bottomTrailing) {
                SaveButton(enabled: !store.draft
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    submitDraft()
                }
                .padding(8)
            }
            // 兜底：点到卡片边距等非文本区域时，先让面板成为键盘焦点窗口再聚焦
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture {
                vm.panel?.makeKey()
                focused = true
            }
            .padding(.horizontal, edgeInset)

            HStack {
                SectionHeader(title: "今天已记（\(store.todayEntries.count)）")
                Spacer()
                if savedFlash {
                    Label("已存入 \(store.inboxFileName)", systemImage: "checkmark")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                        .transition(.opacity)
                }
            }
            // 与输入框内文字左对齐（外边距 + 输入框内边距）
            .padding(.leading, edgeInset + 12)
            .padding(.trailing, edgeInset)

            if let error = store.lastError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.red.opacity(0.9))
                    .lineLimit(1)
                    .padding(.horizontal, edgeInset)
            }

            if store.todayEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.25))
                    Text("今天还没记过，灵感来了别让它跑")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(store.todayEntries) { entry in
                            CaptureRow(entry: entry)
                        }
                    }
                    .padding(.horizontal, edgeInset)
                    .padding(.bottom, 14)
                }
            }
        }
        .onAppear { store.refresh() }
        .onDisappear { vm.keyboardHold = false }
    }

    private func submitDraft() {
        guard store.capture(store.draft) else { return }
        store.draft = ""
        flashSaved()
    }

    private func flashSaved() {
        withAnimation(.easeOut(duration: 0.15)) { savedFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeIn(duration: 0.3)) { savedFlash = false }
        }
    }
}

/// 输入卡片右下角的存入按钮：整个按钮形状可点击、悬停高亮，内容为空时置灰
private struct SaveButton: View {
    let enabled: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("存入")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(enabled ? 0.85 : 0.35))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(hovering && enabled ? 0.2 : 0.12)))
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help("存入收件箱文件（回车只换行，不会误存）")
    }
}

private struct CaptureRow: View {
    @EnvironmentObject var store: CaptureStore
    let entry: CaptureEntry

    @State private var hovering = false
    @State private var deleteHovering = false

    private var preview: String {
        entry.content.replacingOccurrences(of: "\n", with: " ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.time)
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(.white.opacity(0.35))
                .frame(width: 40, alignment: .leading)
            Text(preview)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button {
                withAnimation(.easeOut(duration: 0.15)) { store.delete(entry) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(deleteHovering ? .red : .white.opacity(0.5))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { deleteHovering = $0 }
            .help("从收件箱删除这条")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(hovering ? 0.12 : 0.05)))
        .onHover { hovering = $0 }
        .help(entry.content)
    }
}
