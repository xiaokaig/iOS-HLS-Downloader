import SwiftUI
import UIKit

enum BuildIdentity {
    private static let info = Bundle.main.infoDictionary ?? [:]

    static let appVersion = info["CFBundleShortVersionString"] as? String ?? "未知"
    static let buildNumber = info["CFBundleVersion"] as? String ?? "LOCAL"
    static let internalVersion = "DEV-\(buildNumber)"
    static let commit: String = {
        let value = info["InternalGitCommit"] as? String ?? "LOCAL"
        return String(value.prefix(7))
    }()

    static var copyText: String {
        "HLS 下载器\n应用版本：\(appVersion)\n内部版本：\(internalVersion)\n构建编号：\(buildNumber)\nGit Commit：\(commit)"
    }

    static func copyToPasteboard() {
        UIPasteboard.general.string = copyText
    }
}

struct BuildIdentityBadge: View {
    var body: some View {
        Button(action: BuildIdentity.copyToPasteboard) {
            VStack(spacing: 3) {
                Text("内部版本 \(BuildIdentity.internalVersion)")
                    .font(.caption.weight(.medium).monospaced())
                Text("Commit \(BuildIdentity.commit) · 点击复制构建信息")
                    .font(.caption2.monospaced())
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("复制构建信息")
    }
}
