import SwiftUI

/// 页面出场动画触发器：切页（视图随 .id 重建走 onAppear）或面板展开时重播，收起时复位。
/// 各页用 played 驱动自己的出场形态——启动台图标波浪弹出 / 闪问从底部升起 /
/// 额度进度条充能 / Agent 会话卡逐张发牌
struct PageEntrance: ViewModifier {
    @EnvironmentObject var vm: NotchViewModel
    @Binding var played: Bool

    func body(content: Content) -> some View {
        content
            // 触发统一收进 .task(id:)，不再用 onAppear + onChange 组合：
            // 闪问等非常驻页只在导航到它时才随 .id/.transition 插入挂载。用快捷键
            // 首次呼出时，ChatView 恰是在 isExpanded false→true 的同一拍里随过渡插入的
            // 全新实例，此刻只有 onAppear 能驱动出场——而随过渡插入的子树，其 onAppear
            // 在这种「展开动画同拍插入」场景会漏触发，replay 没跑，元素停在 opacity 0，
            // 整页空白（正是「第一次呼出没有 UI、第二次才正常」的根因：第二次 ChatView
            // 已常驻，走 onChange 稳定路径）。
            // .task 挂载即跑一次、且随 id（isExpanded）翻转重跑，对「全新实例随展开同拍
            // 挂载」稳定不漏；展开→replay，收起→复位。
            .task(id: vm.isExpanded) {
                if vm.isExpanded { replay() } else { played = false }
            }
    }

    private func replay() {
        // 常驻内容树在收起状态也会构建：此时只复位，等展开再播
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
