import SwiftUI

// 设置页设计语言（2026-09-21 最终版，大梁老师定）：
// - 选择控件只留一种：单选用分段（SegmentedPicker），多选用选片（ChipGroup），长列表用下拉（PopupMenu）
// - 点亮即在用：选片、磁贴靠亮暗表示状态，不加对勾、不加外框
// - 按钮只用文字（TextButton）：白色为操作、红色为破坏性；实心按钮只在弹层的「完成」
// - 卡片无描边、无状态圆点；副标题只留会改变决定的
// - 深层内容折进弹层 / 条件显示，页面默认一屏放下

struct PageTitle: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 17, weight: .semibold)).foregroundColor(SettingsTheme.text)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold))
            .foregroundColor(SettingsTheme.textSecondary).padding(.leading, 2)
    }
}

/// 小节标题 + 右侧操作（如「新增」「重新扫描」）
struct SettingsSectionHeader<Trailing: View>: View {
    let text: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack {
            SectionLabel(text: text)
            Spacer()
            trailing
        }
    }
}

/// 说明文字：只在信息会改变用户决定时用
struct SettingsNote: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundColor(SettingsTheme.textMuted)
            .fixedSize(horizontal: false, vertical: true).padding(.leading, 2)
    }
}

/// 卡片：实色填充、无描边
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(SettingsTheme.card))
    }
}

struct CardDivider: View {
    var body: some View {
        Rectangle().fill(SettingsTheme.divider).frame(height: 1).padding(.leading, 14)
    }
}

/// 标准行：左标题（可带副标题），右侧任意控件
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    /// 副标题最多几行（nil = 不限，按内容折行）
    var subtitleLines: Int? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundColor(SettingsTheme.text).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundColor(SettingsTheme.textMuted)
                        .lineLimit(subtitleLines)
                        .fixedSize(horizontal: false, vertical: subtitleLines == nil)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}

/// 上下排的行：标题在上、内容在下（控件太宽放不进一行时用，如四家选片）
struct SettingsVRow<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundColor(SettingsTheme.text)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundColor(SettingsTheme.textMuted)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}

/// 未授权 / 出错时才出现的警告行：红字 + 一个操作
struct WarningRow: View {
    let text: String
    let action: String
    let onAction: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Text(text).font(.system(size: 13)).foregroundColor(SettingsTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            TextButton(title: action, action: onAction)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}

/// 自绘开关：轨道恒定 38×22，开/关只变颜色与滑块位置；开启色是 Claude 陶土橙
struct ThemedSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? SettingsTheme.accent : SettingsTheme.switchOff)
                    .frame(width: 38, height: 22)
                Circle().fill(.white).frame(width: 18, height: 18).padding(2)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            }
            // 绑定的值从别处改（联动、面板按钮）也要滑过去，不能只靠点击那一下的 withAnimation
            .animation(.spring(response: 0.25, dampingFraction: 0.9), value: isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 单选分段控件：一个整体框，选中段变亮
struct SegmentedPicker<T: Hashable>: View {
    let options: [T]
    let title: (T) -> String
    @Binding var selection: T
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { opt in
                let on = opt == selection
                Button { selection = opt } label: {
                    Text(title(opt)).font(.system(size: 12))
                        .foregroundColor(on ? SettingsTheme.text : SettingsTheme.textSecondary)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background {
                            // 同一个高亮块在选项之间滑动（matchedGeometryEffect），不是各画各的瞬跳
                            if on {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(SettingsTheme.fillOn)
                                    .matchedGeometryEffect(id: "selected", in: highlight)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SettingsTheme.segmentBg))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selection)
    }
}

/// 多选选片：点亮即选中，不加对勾
struct ChipGroup<T: Hashable>: View {
    let options: [T]
    let title: (T) -> String
    let isOn: (T) -> Bool
    let toggle: (T) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { opt in
                let on = isOn(opt)
                Button { toggle(opt) } label: {
                    Text(title(opt)).font(.system(size: 12))
                        .foregroundColor(on ? SettingsTheme.text : SettingsTheme.textMuted)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(on ? SettingsTheme.fillOn : SettingsTheme.fillOff))
                        .contentShape(Rectangle())
                        .animation(.easeOut(duration: 0.15), value: on)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 磁贴：并列同类项做成一排方块，只有图标/品牌点＋名字，点亮即启用。
/// 直接落在窗口底上，不嵌卡片（大梁老师 2026-09-21 定）
struct SettingsTile<Leading: View>: View {
    let title: String
    let isOn: Bool
    let action: () -> Void
    @ViewBuilder var leading: Leading

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                leading
                Text(title).font(.system(size: 13))
                    .foregroundColor(isOn ? SettingsTheme.text : SettingsTheme.textMuted)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .layoutPriority(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isOn ? SettingsTheme.tileOn : SettingsTheme.fillOff))
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: isOn)
        }
        .buttonStyle(.plain)
    }
}

/// 文字按钮：白色中等字重为操作，红色为破坏性
struct TextButton: View {
    let title: String
    var destructive = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium))
                .foregroundColor(disabled ? SettingsTheme.textMuted
                                 : (destructive ? SettingsTheme.danger : SettingsTheme.text))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/// 下拉：当前值 + 上下箭头，无底色
struct PopupMenu<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        // 箭头用 Text 内嵌图片拼在文字后面：macOS 的 Menu 标签若给独立 Image，会被排到标题左边
        Menu { content } label: {
            (Text(label) + Text("  ")
                + Text(Image(systemName: "chevron.up.chevron.down")).font(.system(size: 9))
                    .foregroundColor(SettingsTheme.textMuted))
                .font(.system(size: 12)).foregroundColor(SettingsTheme.textSecondary)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}

/// 滑块行（光晕外观）
struct SettingsSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let display: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13)).foregroundColor(SettingsTheme.text)
                .frame(width: 72, alignment: .leading)
            Slider(value: $value, in: range).controlSize(.small).tint(SettingsTheme.accent)
            Text(display).font(.system(size: 12)).foregroundColor(SettingsTheme.textMuted)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

/// 弹层里的文本输入（有底色的框）
struct ThemedTextField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false

    var body: some View {
        Group {
            if secure {
                SecureField("", text: $text, prompt: Text(placeholder).foregroundColor(SettingsTheme.textMuted))
            } else {
                TextField("", text: $text, prompt: Text(placeholder).foregroundColor(SettingsTheme.textMuted))
            }
        }
        .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(SettingsTheme.text)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(SettingsTheme.bg))
    }
}

/// 密钥字段：未编辑时显示固定 16 个圆点，点击切回真实输入框编辑；失焦或回车时回调提交
struct MaskedSecureField: View {
    let placeholder: String
    @Binding var text: String
    var onCommit: () -> Void = {}
    @FocusState private var focused: Bool
    @State private var editing = false

    var body: some View {
        if editing || text.isEmpty {
            SecureField("", text: $text, prompt: Text(placeholder).foregroundColor(SettingsTheme.textMuted))
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(SettingsTheme.text)
                .frame(maxWidth: .infinity)
                .focused($focused)
                .onSubmit { focused = false }
                .onChange(of: focused) { _, now in
                    if !now { editing = false; onCommit() }
                }
        } else {
            Button {
                editing = true
                DispatchQueue.main.async { focused = true }
            } label: {
                Text(String(repeating: "•", count: 16))
                    .font(.system(size: 13)).foregroundColor(SettingsTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("点击修改")
        }
    }
}

/// 弹层的状态行：圆点 + 文字（只在弹层里用，页面上不用圆点）
struct StatusLine: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.system(size: 12)).foregroundColor(SettingsTheme.text).lineLimit(1)
        }
    }
}
