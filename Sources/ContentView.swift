import SwiftUI

struct ContentView: View {
    @State private var address = "https://example.com"
    @State private var candidates: [URL] = []
    @State private var candidateCookies: [String: [HTTPCookie]] = [:]
    @State private var variantOptions: [HLSVariant] = []
    @State private var pendingCookies: [HTTPCookie] = []
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
                                Button("解析") {
                                    inspectCandidate(candidate)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(downloader.isDownloading)
                            }
                        }
                    }
                    .padding()
                    .frame(maxHeight: 190)
                }

                if !variantOptions.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("选择清晰度")
                            .font(.headline)
                        ForEach(variantOptions) { variant in
                            Button {
                                let cookies = pendingCookies
                                variantOptions = []
                                startDownload(variant.url, cookies: cookies)
                            } label: {
                                HStack {
                                    Text(variant.resolution ?? "分辨率未知")
                                    Spacer()
                                    Text(variant.bandwidth > 0 ? String(format: "%.1f Mbps", Double(variant.bandwidth) / 1_000_000) : "码率未知")
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(downloader.isDownloading)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .frame(maxHeight: 180)
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

    private func inspectCandidate(_ url: URL) {
        let cookies = candidateCookies[url.absoluteString] ?? []
        errorMessage = nil
        Task {
            do {
                let variants = try await downloader.variants(for: url, cookies: cookies)
                if variants.isEmpty {
                    startDownload(url, cookies: cookies)
                } else {
                    pendingCookies = cookies
                    variantOptions = variants
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startDownload(_ url: URL, cookies: [HTTPCookie]) {
        errorMessage = nil
        Task {
            do {
                _ = try await downloader.start(url: url, cookies: cookies)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
