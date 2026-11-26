import SwiftUI

struct ContentView: View {
    @State private var address = "https://example.com"
    @State private var candidates: [URL] = []
    @State private var candidateCookies: [String: [HTTPCookie]] = [:]
    @State private var selectedCandidate: URL?
    @State private var errorMessage: String?
    @StateObject private var downloader = HLSDownloadManager()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("输入网址", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { navigate() }
                    Button(action: navigate) {
                        Image(systemName: "arrow.forward")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("打开网页")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                BrowserView(
                    address: address,
                    onCapture: addCandidate,
                    onAddressChange: { address = $0 }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !candidates.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("发现的 M3U8 地址")
                                .font(.headline)
                            Spacer()
                            Text("\(candidates.count)")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(candidates, id: \.absoluteString) { candidate in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.lastPathComponent.isEmpty ? candidate.host ?? candidate.absoluteString : candidate.lastPathComponent)
                                        .lineLimit(1)
                                    Text(candidate.host ?? candidate.absoluteString)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button("下载") {
                                    selectedCandidate = candidate
                                    startDownload(candidate)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(downloader.isDownloading)
                            }
                        }
                    }
                    .padding()
                    .frame(maxHeight: 190)
                }

                VStack(spacing: 6) {
                    HStack {
                        Text(downloader.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if downloader.isDownloading {
                            Text(downloader.progress, format: .percent.precision(.fractionLength(0)))
                                .font(.caption.monospacedDigit())
                        }
                    }
                    if downloader.isDownloading {
                        ProgressView(value: downloader.progress)
                    }
                    if let file = downloader.outputURL {
                        ShareLink(item: file) {
                            Label("导出到文件 / 分享", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .navigationTitle("HLS 下载器")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func navigate() {
        let raw = address.contains("://") ? address : "https://" + address
        address = raw
    }

    private func addCandidate(_ url: URL, cookies: [HTTPCookie]) {
        candidateCookies[url.absoluteString] = cookies
        guard !candidates.contains(where: { $0.absoluteString == url.absoluteString }) else { return }
        candidates.insert(url, at: 0)
        if candidates.count > 20 { candidates.removeLast(candidates.count - 20) }
    }

    private func startDownload(_ url: URL) {
        errorMessage = nil
        Task {
            do {
                _ = try await downloader.start(url: url, cookies: candidateCookies[url.absoluteString] ?? [])
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
