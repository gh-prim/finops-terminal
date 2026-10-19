import FinopsCore
import SwiftUI

// MARK: Ticker tape

/// A stock-exchange tape: live prices scrolling past, ▲ green / ▼ red. Horizontal in
/// a wide tile (top or bottom of the screen), vertical in a tall one (a side column).
struct TickerWidget: View {
    let widget: DashWidget
    let client: DataClient

    @State private var quotes: [String: Quote] = [:]
    @State private var length: CGFloat = 0
    /// Scroll position at a reference time; moving it when the tape's length changes
    /// keeps the motion continuous (a price getting a digit wider no longer makes it jump).
    @State private var anchor = (time: Date.timeIntervalSinceReferenceDate, offset: CGFloat(0))

    private var pointsPerSecond: CGFloat { CGFloat([25, 45, 75][min(max(widget.speed, 1), 3) - 1]) }

    var body: some View {
        GeometryReader { geo in
            let vertical = geo.size.height > geo.size.width
            TimelineView(.animation) { context in
                let offset = position(at: context.date.timeIntervalSinceReferenceDate)
                tape(vertical: vertical)
                    .drawingGroup()  // rasterize once per content change; scrolling is then a cheap GPU move
                    .offset(x: vertical ? 0 : -offset, y: vertical ? -offset : 0)
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

    private func position(at time: TimeInterval) -> CGFloat {
        guard length > 0 else { return 0 }
        let raw = anchor.offset + CGFloat(time - anchor.time) * pointsPerSecond
        return raw.truncatingRemainder(dividingBy: length)
    }

    private func setLength(_ new: CGFloat) {
        guard abs(new - length) > 0.5 else { return }
        let now = Date.timeIntervalSinceReferenceDate
        let current = position(at: now)
        anchor = (now, new > 0 ? current.truncatingRemainder(dividingBy: new) : 0)
        length = new
    }

    /// Two copies back to back, so the loop is seamless.
    @ViewBuilder
    private func tape(vertical: Bool) -> some View {
        if vertical {
            VStack(alignment: .leading, spacing: 0) {
                strip(vertical: true).background(measure(vertical: true))
                strip(vertical: true)
            }
        } else {
            HStack(spacing: 0) {
                strip(vertical: false).background(measure(vertical: false))
                strip(vertical: false)
            }
        }
    }

    private func measure(vertical: Bool) -> some View {
        GeometryReader { g in
            Color.clear
                .onAppear { setLength(vertical ? g.size.height : g.size.width) }
                .onChange(of: g.size) { setLength(vertical ? g.size.height : g.size.width) }
        }
    }

    @ViewBuilder
    private func strip(vertical: Bool) -> some View {
        if vertical {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(widget.securities, id: \.self) { item($0, vertical: true) }
            }
            .fixedSize()
        } else {
            HStack(spacing: 0) {
                ForEach(widget.securities, id: \.self) { item($0, vertical: false) }
            }
            .fixedSize()
        }
    }

    private func item(_ security: String, vertical: Bool) -> some View {
        let quote = quotes[security]
        let change = quote?.changePct
        let arrow = change.map { $0 > 0 ? "▲" : $0 < 0 ? "▼" : "■" } ?? ""
        let price = Text(quote.map { Format.price($0.last) } ?? "—").foregroundStyle(Palette.text)
        let move = Text("\(arrow) \(Format.percent(change))").foregroundStyle(Palette.direction(change))
        return Group {
            if vertical {
                VStack(alignment: .leading, spacing: 1) {
                    Text(shortName(security)).foregroundStyle(Palette.accent)
                    HStack(spacing: 6) { price; move }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(width: DashboardView.bandThickness.vertical, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1) }
            } else {
                HStack(spacing: 6) {
                    Text(shortName(security)).foregroundStyle(Palette.accent)
                    price
                    move
                }
                .padding(.horizontal, 14)
                .overlay(alignment: .trailing) { Rectangle().fill(Palette.border).frame(width: 1, height: 14) }
            }
        }
        .font(.system(size: 13, weight: .semibold, design: .monospaced))
        .monospacedDigit()
        .lineLimit(1)
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
