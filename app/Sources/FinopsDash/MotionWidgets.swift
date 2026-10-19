import FinopsCore
import SwiftUI

// MARK: Ticker tape

/// A stock-exchange tape: live prices scrolling past, ▲ green / ▼ red. Horizontal in
/// a wide tile (top or bottom of the screen), vertical in a tall one (a side column).
struct TickerWidget: View {
    let widget: DashWidget
    let client: DataClient

    @State private var quotes: [String: Quote] = [:]
    @State private var length: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let vertical = geo.size.height > geo.size.width
            let pointsPerSecond = CGFloat([30, 55, 90][min(max(widget.speed, 1), 3) - 1])
            TimelineView(.animation) { context in
                let travelled = CGFloat(context.date.timeIntervalSinceReferenceDate) * pointsPerSecond
                let offset = -travelled.truncatingRemainder(dividingBy: max(length, 1))
                Group {
                    if vertical {
                        VStack(alignment: .leading, spacing: 0) { strip(vertical: true); strip(vertical: true) }
                            .offset(y: offset)
                    } else {
                        HStack(spacing: 0) { strip(vertical: false); strip(vertical: false) }
                            .offset(x: offset)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
            .clipped()
        }
        .task(id: widget.securities) {
            await withTaskGroup(of: Void.self) { group in
                for security in widget.securities {
                    group.addTask { await stream(security) }
                }
            }
        }
    }

    /// One full pass of the tape; drawn twice back to back so the loop is seamless.
    @ViewBuilder
    private func strip(vertical: Bool) -> some View {
        let items = ForEach(widget.securities, id: \.self) { item($0, vertical: vertical) }
        Group {
            if vertical {
                VStack(alignment: .leading, spacing: 0) { items }
            } else {
                HStack(spacing: 0) { items }
            }
        }
        .fixedSize()
        .background(GeometryReader { g in
            Color.clear.onAppear { length = vertical ? g.size.height : g.size.width }
                .onChange(of: g.size) { length = vertical ? g.size.height : g.size.width }
        })
    }

    private func item(_ security: String, vertical: Bool) -> some View {
        let quote = quotes[security]
        let change = quote?.changePct
        let arrow = change.map { $0 > 0 ? "▲" : $0 < 0 ? "▼" : "■" } ?? ""
        return HStack(spacing: 6) {
            Text(shortName(security)).foregroundStyle(Palette.accent)
            Text(quote.map { Format.price($0.last) } ?? "—").foregroundStyle(Palette.text)
            Text("\(arrow) \(Format.percent(change))").foregroundStyle(Palette.direction(change))
        }
        .font(.system(size: 15, weight: .semibold, design: .monospaced))
        .lineLimit(1)
        .padding(.horizontal, vertical ? 8 : 18)
        .padding(.vertical, vertical ? 7 : 0)
        .frame(maxHeight: vertical ? nil : .infinity)
        .overlay(alignment: vertical ? .bottom : .trailing) {
            Rectangle().fill(Palette.border).frame(width: vertical ? nil : 1, height: vertical ? 1 : 18)
        }
    }

    private func stream(_ security: String) async {
        for await event in await client.subscribe(security) {
            if case .tick(let quote) = event {
                await MainActor.run { quotes[security] = quote }
            }
        }
    }
}

// MARK: Slideshow

/// Cycles through its slides (any widget kinds) every `seconds`, with page dots.
struct CarouselWidget: View {
    let widget: DashWidget
    let client: DataClient?

    @State private var index = 0

    var body: some View {
        let slides = widget.slides
        ZStack(alignment: .bottomTrailing) {
            if slides.isEmpty {
                WidgetMessage(text: "Empty slideshow: add slides in the builder")
            } else {
                let slide = sized(slides[index % slides.count])
                WidgetView(widget: slide, client: client)
                    .id(slide.id)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
                if slides.count > 1 {
                    HStack(spacing: 5) {
                        ForEach(slides.indices, id: \.self) { i in
                            Circle().fill(i == index % slides.count ? Palette.accent : Palette.muted.opacity(0.5))
                                .frame(width: 6, height: 6)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .clipped()
        .task(id: "\(widget.seconds)|\(slides.count)") {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(widget.seconds, 3)))
                withAnimation(.easeInOut(duration: 0.6)) { index += 1 }
            }
        }
    }

    /// Slides take the carousel's footprint, so size-dependent layouts (quote columns) fit.
    private func sized(_ slide: DashWidget) -> DashWidget {
        var slide = slide
        slide.x = widget.x
        slide.y = widget.y
        slide.w = widget.w
        slide.h = widget.h
        return slide
    }
}
