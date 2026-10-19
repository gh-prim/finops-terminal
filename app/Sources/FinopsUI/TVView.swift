import FinopsDash
import SwiftUI
import WebKit

/// TV: live business television through YouTube's official embed player.
struct TVView: View {
    struct Channel: Identifiable, Hashable {
        let id: String
        let name: String
        let embed: String   // path after youtube.com/embed/
    }

    /// Live streams get a new video ID per broadcast, so each channel also has its
    /// "current live" form (embed/live_stream?channel=…), which always follows the stream.
    static let channels = [
        Channel(id: "BLOOMBERG", name: "Bloomberg TV", embed: "QB5BNdBFujE"),
        Channel(id: "BLOOMBERG-LIVE", name: "Bloomberg TV (current live)", embed: "live_stream?channel=UCIALMKvObZNtJ6AmdCLP7Lg"),
    ]

    let args: [String]
    let run: (String) -> Void

    private var selection: (name: String, embed: String) {
        if let arg = args.first {
            if let channel = Self.channels.first(where: { $0.id == arg }) { return (channel.name, channel.embed) }
            // Any other argument is treated as a YouTube video ID (case matters, so use the original text).
            return ("YouTube \(arg)", arg)
        }
        return (Self.channels[0].name, Self.channels[0].embed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(Self.channels) { channel in
                    Button(channel.name) { run("TV \(channel.id)") }
                        .buttonStyle(TerminalButtonStyle(selected: selection.embed == channel.embed))
                }
                Spacer()
                Text("Source: YouTube (official embed)").font(.terminalSmall).foregroundStyle(Palette.muted)
            }
            YouTubePlayer(embed: selection.embed)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text("If the stream has moved to a new broadcast, pick “current live”. Type TV <video-id> for any other YouTube live.")
                .font(.terminalSmall).foregroundStyle(Palette.muted)
        }
        .padding(12)
    }
}

/// YouTube's iframe player inside a WKWebView (an https origin is required by the embed).
struct YouTubePlayer {
    let embed: String

    private var html: String {
        let separator = embed.contains("?") ? "&" : "?"
        let src = "https://www.youtube.com/embed/\(embed)\(separator)autoplay=1&playsinline=1&rel=0&modestbranding=1"
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000}iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style>
        </head><body><iframe src="\(src)" allow="autoplay; encrypted-media; picture-in-picture; fullscreen"
        allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe></body></html>
        """
    }

    @MainActor
    static func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        #endif
        let view = WKWebView(frame: .zero, configuration: config)
        #if os(macOS)
        view.setValue(false, forKey: "drawsBackground")
        #else
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        #endif
        return view
    }

    @MainActor
    func load(into view: WKWebView, coordinator: Coordinator) {
        guard coordinator.loaded != embed else { return }
        coordinator.loaded = embed
        view.loadHTMLString(html, baseURL: URL(string: "https://finops-terminal.app/"))
    }

    final class Coordinator {
        var loaded: String?
    }
}

#if os(macOS)
extension YouTubePlayer: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView { Self.makeWebView() }
    func updateNSView(_ view: WKWebView, context: Context) { load(into: view, coordinator: context.coordinator) }
}
#else
extension YouTubePlayer: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView { Self.makeWebView() }
    func updateUIView(_ view: WKWebView, context: Context) { load(into: view, coordinator: context.coordinator) }
}
#endif
