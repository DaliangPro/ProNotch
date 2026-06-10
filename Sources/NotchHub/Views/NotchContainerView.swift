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
            NotchShape(topRadius: vm.isExpanded ? 12 : 6,
                       bottomRadius: vm.isExpanded ? 20 : 10)
                .fill(Color.black)
                .frame(width: shapeWidth, height: shapeHeight)
                .shadow(color: .black.opacity(vm.isExpanded ? 0.55 : 0),
                        radius: 14, y: 5)

            if vm.isExpanded {
                ExpandedContentView()
                    .frame(width: shapeWidth, height: shapeHeight)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
