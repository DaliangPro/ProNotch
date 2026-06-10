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
            // 输入区：回车存入，⌥+回车换行
            ZStack(alignment: .topLeading) {
                // 自绘占位文字：比正文小一号且用细体（prompt 不支持自定字体）
                if store.draft.isEmpty {
                    Text("记下一闪而过的灵感，回车存入 Obsidian（⌥+回车换行）")
                        .font(.system(size: 12, weight: .light))
                        .foregroundColor(.white.opacity(0.3))
                        .allowsHitTesting(false)
                }
                TextField("", text: $store.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .lineLimit(3...6)
                    .focused($focused)
                    .onSubmit { submitDraft() }
                    .onChange(of: focused) { vm.keyboardHold = $0 }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08)))
            // 整张输入卡片任意位置点击都能唤起光标，不限于文字所在的第一行
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture { focused = true }
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
