import SwiftUI

/// 页面出场动画触发器：切页（视图随 .id 重建走 onAppear）或面板展开时重播，收起时复位。
/// 各页用 played 驱动自己的出场形态——启动台图标波浪弹出 / 闪问从底部升起 /
/// 额度进度条充能 / Agent 会话卡逐张发牌
struct PageEntrance: ViewModifier {
    @EnvironmentObject var vm: NotchViewModel
    @Binding var played: Bool

    func body(content: Content) -> some View {
        content
            .onAppear { replay() }
            .onChange(of: vm.isExpanded) { _, expanded in
                if expanded { replay() } else { played = false }
            }
    }

    private func replay() {
        // 常驻内容树在收起状态也会构建：此时只复位，等展开的 onChange 再播
        guard vm.isExpanded else { played = false; return }
        played = false
        // 初始态先上屏一帧再翻 true，元素才有从起点到终点的路可走；
        // 0.10s 起播赶上面板 +8% 过冲（峰值约 0.21s，内容淡入 0.05s 起、0.17s 齐）——
        // 出场叠在弹跳上跑才有 NookX 那种「内容跟着蹦」的感觉
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { played = true }
    }
}

extension View {
    /// 挂在页面根视图上；played 为该页出场动画的驱动开关
    func pageEntrance(_ played: Binding<Bool>) -> some View {
        modifier(PageEntrance(played: played))
    }
}
