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
            // 内容常驻、只做透明度门控（淡入仍延迟到面板长到六成，收起先快速隐去）——
            // 旧写法 if isExpanded 每次展开都从零重建整棵内容树，边长面板边搭视图必掉帧，
            // 这是展开动画不丝滑的主因；常驻后展开只剩形状与透明度动画
            ExpandedContentView()
                .frame(width: vm.expandedShapeSize.width,
                       height: vm.expandedShapeSize.height,
                       alignment: .top)
                .opacity(vm.isExpanded ? 1 : 0)
                .animation(vm.isExpanded ? .easeOut(duration: 0.2).delay(0.15)
                                         : .easeIn(duration: 0.1),
                           value: vm.isExpanded)
                .allowsHitTesting(vm.isExpanded)
        }
        .frame(width: shapeWidth, height: shapeHeight, alignment: .top)
        .clipShape(NotchShape(topRadius: vm.isExpanded ? 12 : 6,
                              bottomRadius: vm.isExpanded ? 20 : 10))
        .shadow(color: .black.opacity(vm.isExpanded ? 0.55 : 0), radius: 14, y: 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
