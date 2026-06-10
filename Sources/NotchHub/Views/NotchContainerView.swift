import SwiftUI

/// 窗口根视图：绘制刘海黑色形状，承载悬停检测与展开内容
struct NotchContainerView: View {
    @EnvironmentObject var vm: NotchViewModel

    private var shapeWidth: CGFloat {
        vm.isExpanded ? vm.expandedShapeSize.width : vm.notchRect.width
    }

    private var shapeHeight: CGFloat {
        vm.isExpanded ? vm.expandedShapeSize.height : vm.notchRect.height
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            if vm.isExpanded {
                // 内容固定按最终尺寸排版，由外层 clipShape 随面板生长逐步显露，
                // 淡入延迟到面板长到六成后开始；收起时内容先快速消失再缩面板
                ExpandedContentView()
                    .frame(width: vm.expandedShapeSize.width,
                           height: vm.expandedShapeSize.height,
                           alignment: .top)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.15)),
                        removal: .opacity.animation(.easeIn(duration: 0.1))))
            }
        }
        .frame(width: shapeWidth, height: shapeHeight, alignment: .top)
        .clipShape(NotchShape(topRadius: vm.isExpanded ? 12 : 6,
                              bottomRadius: vm.isExpanded ? 20 : 10))
        .shadow(color: .black.opacity(vm.isExpanded ? 0.55 : 0), radius: 14, y: 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
