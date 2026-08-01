import SwiftUI

/// 页面出场动画触发器：切页（视图随 .id 重建走 onAppear）或面板展开时重播，收起时复位。
/// 各页用 played 驱动自己的出场形态——启动台图标波浪弹出 / 闪问从底部升起 /
/// 额度进度条充能 / Agent 会话卡逐张发牌
struct PageEntrance: ViewModifier {
    @EnvironmentObject var vm: NotchViewModel
    @Binding var played: Bool
    /// 出场动画的驱动开关。
    ///
    /// nil ＝ 跟刘海展开态走，这是刘海内各页的默认。独立窗口必须显式传 true：
    /// 那里的 `isExpanded` 说的是**刘海**的状态，跟这个窗口毫无关系——
    /// 刘海收着的时候它恒为 false，出场永远不播，整页元素停在 opacity 0，窗口一片空白
    var active: Bool?

    /// 切页新挂载（刘海已展开时随 .id 重建）要不要重播出场。
    ///
    /// 默认 true＝老行为。闪问页传 false（大梁老师 2026-07-31「反复强调切进闪问卡顿」）：
    /// 它的出场是十几条消息逐条发牌，切页也重播的话，页面滑到位了内容还要
    /// 半秒多才亮齐——体感就是「进去卡顿」。改成切页即现后，只有
    /// 刘海**展开**那一下（driver false→true）才播发牌，与面板弹跳叠着跑的
    /// 设计保留不动
    var replayOnRemount = true

    /// 是否已挂载过：区分「切页新挂载」与「挂着时展开态翻转」两种触发
    @State private var mounted = false

    /// 真正驱动出场的那个值
    private var driver: Bool { active ?? vm.isExpanded }

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
            .task(id: driver) {
                defer { mounted = true }
                if driver {
                    // 挂载那一刻刘海就已展开＝从别的页切过来（或独立窗口首开）。
                    // 不重播的页直接亮齐，内容跟着页面过渡一起到位
                    if !mounted, !replayOnRemount {
                        played = true
                    } else {
                        replay()
                    }
                } else {
                    played = false
                }
            }
    }

    private func replay() {
        // 常驻内容树在收起状态也会构建：此时只复位，等展开再播
        guard driver else { played = false; return }
        played = false
        // 初始态先上屏一帧再翻 true，元素才有从起点到终点的路可走；
        // 0.10s 起播赶上面板 +8% 过冲（峰值约 0.21s，内容淡入 0.05s 起、0.17s 齐）——
        // 出场叠在弹跳上跑才有 NookX 那种「内容跟着蹦」的感觉
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { played = true }
    }
}

extension View {
    /// 挂在页面根视图上；played 为该页出场动画的开关。
    /// `active` 留空＝跟刘海展开态走；独立窗口须传 true（理由见 PageEntrance.active）。
    /// `replayOnRemount: false`＝切页新挂载不重播、内容即现（闪问页用，理由见同名属性）
    func pageEntrance(_ played: Binding<Bool>, active: Bool? = nil,
                      replayOnRemount: Bool = true) -> some View {
        modifier(PageEntrance(played: played, active: active, replayOnRemount: replayOnRemount))
    }
}
