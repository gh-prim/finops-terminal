import FinopsCore
import FinopsDash
import SwiftUI
import WebKit

/// READ: an article inside the terminal. Reader mode shows the text extracted by the
/// gateway; Web mode shows the page itself (paywalls, sites that block extraction).
struct ReaderView: View {
    let client: DataClient
    let link: String
    let run: (String) -> Void

    private enum Mode { case reader, web }

    @State private var article: Article?
    @State private var failure: String?
    @State private var loading = false
    @State private var mode: Mode = .reader
    @State private var input = ""
    @Environment(\.openURL) private var openURL

    private var url: URL? {
        guard link.hasPrefix("http://") || link.hasPrefix("https://") else { return nil }
        return URL(string: link)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let url {
                toolbar(url)
                Divider().overlay(Palette.border)
                switch mode {
                case .reader: reader
                case .web: WebPage(url: url)
                }
            } else {
                prompt
            }
        }
        .task(id: link) { await load() }
    }

    private func toolbar(_ url: URL) -> some View {
        HStack(spacing: 4) {
            Button("Reader") { mode = .reader }
                .buttonStyle(TerminalButtonStyle(selected: mode == .reader))
                .disabled(article?.readable != true)
                .help(article?.readable == false ? "No full text for this page (paywall or not an article)" : "Text only")
            Button("Web") { mode = .web }
                .buttonStyle(TerminalButtonStyle(selected: mode == .web))
            Text(article?.site ?? url.host() ?? "")
                .font(.terminalSmall).foregroundStyle(Palette.muted).lineLimit(1)
                .padding(.leading, 8)
            Spacer()
            Button { openURL(url) } label: { Label("Open in browser", systemImage: "safari") }
                .buttonStyle(TerminalButtonStyle(selected: false))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    @ViewBuilder
    private var reader: some View {
        if let article, article.readable {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(article.title ?? "")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .textSelection(.enabled)
                    Text([article.site, article.author, article.date].compactMap { $0 }.joined(separator: " · "))
                        .font(.terminalSmall).foregroundStyle(Palette.muted)
                    ForEach(Array(article.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .foregroundStyle(Palette.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
        } else if loading {
            ProgressView().controlSize(.small).padding(14)
        } else {
            // Extraction failed: fall back to the page itself.
            WebPage(url: url!)
        }
    }

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reader").font(.system(size: 14, weight: .semibold, design: .monospaced))
            Text("Paste a link to read it here, or click any headline in NEWS, NEWS CRYPTO or CRYPTO.")
                .foregroundStyle(Palette.muted)
            TextField("https://…", text: $input)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 520)
                .onSubmit {
                    let link = input.trimmingCharacters(in: .whitespaces)
                    if !link.isEmpty { run("READ \(link)") }
                }
            if !link.isEmpty {
                Text("“\(link)” is not a web link.").foregroundStyle(Palette.down)
            }
        }
        .padding(14)
    }

    private func load() async {
        article = nil
        failure = nil
        mode = .reader
        guard url != nil else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await client.article(link)
            article = result
            if !result.readable { mode = .web }
        } catch {
            failure = error.localizedDescription
            mode = .web
        }
    }
}

/// A plain web page (default, persistent website data, so cookie choices are remembered).
struct WebPage {
    let url: URL

    @MainActor
    static func makeWebView() -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.allowsBackForwardNavigationGestures = true
        return view
    }

    @MainActor
    func load(into view: WKWebView, coordinator: Coordinator) {
        guard coordinator.loaded != url else { return }
        coordinator.loaded = url
        view.load(URLRequest(url: url))
    }

    final class Coordinator {
        var loaded: URL?
    }
}

#if os(macOS)
extension WebPage: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView { Self.makeWebView() }
    func updateNSView(_ view: WKWebView, context: Context) { load(into: view, coordinator: context.coordinator) }
}
#else
extension WebPage: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView { Self.makeWebView() }
    func updateUIView(_ view: WKWebView, context: Context) { load(into: view, coordinator: context.coordinator) }
}
#endif
