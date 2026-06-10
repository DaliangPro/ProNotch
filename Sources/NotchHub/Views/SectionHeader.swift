import SwiftUI

/// 面板内分区标题（启动台、剪贴板等共用）
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white.opacity(0.4))
    }
}
