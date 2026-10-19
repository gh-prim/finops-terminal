import FinopsCore
import SwiftUI

/// World map of events, drawn by the terminal itself (Natural Earth outlines, equirectangular):
/// the whole world always fits the frame. Colour = type, size = severity. Clicking a point runs
/// its command (LINK <entity>) or opens its source in the reader.
public struct MapBlockView: View {
    let block: GatewayDocument.MapBlock
    let run: (String) -> Void
    var height: CGFloat? = 420

    @State private var selected: GatewayDocument.MapBlock.Point?

    /// Latitudes shown: Antarctica and the far Arctic carry no market events.
    static let north = 84.0, south = -58.0

    public init(block: GatewayDocument.MapBlock, run: @escaping (String) -> Void, height: CGFloat? = 420, wholeWorld: Bool = false) {
        self.block = block
        self.run = run
        self.height = height
    }

    public static func color(_ kind: String?) -> Color {
        switch kind {
        case "conflict": Color(red: 0.94, green: 0.33, blue: 0.31)
        case "unrest": Color(red: 1.0, green: 0.55, blue: 0.2)
        case "coercion": Color(red: 0.75, green: 0.45, blue: 1.0)
        case "disaster": Color(red: 1.0, green: 0.85, blue: 0.3)
        case "shipping": Color(red: 0.35, green: 0.65, blue: 1.0)
        case "internet": Color(red: 0.3, green: 0.85, blue: 0.85)
        case "focus": .white
        default: Palette.muted
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = block.title { SectionLabel(title: title) }
            GeometryReader { geo in
                let rect = Self.fit(geo.size)
                ZStack(alignment: .bottomLeading) {
                    Color(red: 0.05, green: 0.07, blue: 0.10)
                    Canvas { context, _ in
                        Self.drawGraticule(&context, rect)
                        Self.drawLand(&context, rect)
                        for point in block.points.sorted(by: { ($0.severity ?? 1) < ($1.severity ?? 1) }) {
                            Self.drawPoint(&context, point, at: Self.project(point.lat, point.lon, rect), selected: point == selected)
                        }
                    }
                    #if !os(tvOS)
                    .onContinuousHover { phase in
                        if case .active(let location) = phase { selected = nearest(location, rect) }
                    }
                    .onTapGesture { location in
                        guard let point = nearest(location, rect) else { return }
                        selected = point
                        if let cmd = point.cmd { run(cmd) } else if let url = point.url { run("READ \(url)") }
                    }
                    #endif
                    legend
                }
            }
            .frame(height: height)
            .frame(maxHeight: height == nil ? .infinity : nil)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            if let selected {
                HStack(alignment: .firstTextBaseline) {
                    Circle().fill(Self.color(selected.kind)).frame(width: 8, height: 8)
                    Text(selected.label).font(.terminalSmall).foregroundStyle(Palette.text).lineLimit(1)
                    if let detail = selected.detail { Text(detail).font(.terminalSmall).foregroundStyle(Palette.muted).lineLimit(1) }
                    Spacer()
                    if selected.cmd != nil || selected.url != nil { Text("click to open").font(.terminalSmall).foregroundStyle(Palette.muted) }
                }
            }
        }
    }

    // MARK: Projection

    /// The largest map rectangle with the projection's aspect ratio, centred in `size`.
    static func fit(_ size: CGSize) -> CGRect {
        let aspect = 360 / (north - south)
        var w = size.width, h = size.width / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    static func project(_ lat: Double, _ lon: Double, _ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + (lon + 180) / 360 * rect.width,
                y: rect.minY + (north - min(max(lat, south), north)) / (north - south) * rect.height)
    }

    private func nearest(_ location: CGPoint, _ rect: CGRect) -> GatewayDocument.MapBlock.Point? {
        let best = block.points.min { a, b in
            Self.distance(Self.project(a.lat, a.lon, rect), location) < Self.distance(Self.project(b.lat, b.lon, rect), location)
        }
        guard let best, Self.distance(Self.project(best.lat, best.lon, rect), location) < 14 else { return nil }
        return best
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    // MARK: Drawing

    /// Natural Earth 110m land rings, [[lon, lat], …], loaded once.
    static let land: [[[Double]]] = {
        guard let url = Bundle.module.url(forResource: "world-land", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let rings = try? JSONDecoder().decode([[[Double]]].self, from: data) else { return [] }
        return rings
    }()

    private static func drawLand(_ context: inout GraphicsContext, _ rect: CGRect) {
        var path = Path()
        for ring in land where ring.count > 2 {
            path.move(to: project(ring[0][1], ring[0][0], rect))
            for p in ring.dropFirst() { path.addLine(to: project(p[1], p[0], rect)) }
            path.closeSubpath()
        }
        context.fill(path, with: .color(Color(red: 0.16, green: 0.17, blue: 0.20)))
        context.stroke(path, with: .color(Color.white.opacity(0.18)), lineWidth: 0.6)
    }

    private static func drawGraticule(_ context: inout GraphicsContext, _ rect: CGRect) {
        var path = Path()
        for lon in stride(from: -150.0, through: 150, by: 30) {
            path.move(to: project(north, lon, rect)); path.addLine(to: project(south, lon, rect))
        }
        for lat in stride(from: -30.0, through: 60, by: 30) {
            path.move(to: project(lat, -180, rect)); path.addLine(to: project(lat, 180, rect))
        }
        context.stroke(path, with: .color(Color.white.opacity(0.05)), lineWidth: 0.5)
        var equator = Path()
        equator.move(to: project(0, -180, rect)); equator.addLine(to: project(0, 180, rect))
        context.stroke(equator, with: .color(Color.white.opacity(0.09)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
    }

    private static func drawPoint(_ context: inout GraphicsContext, _ point: GatewayDocument.MapBlock.Point, at center: CGPoint,
                                  selected: Bool) {
        let r = CGFloat(2.5 + 2 * Double(point.severity ?? 1)) * (selected ? 1.6 : 1)
        let color = color(point.kind)
        let dot = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        if point.severity == 3 || selected {
            let halo = Path(ellipseIn: CGRect(x: center.x - r * 2, y: center.y - r * 2, width: 4 * r, height: 4 * r))
            context.fill(halo, with: .color(color.opacity(0.15)))
        }
        context.fill(dot, with: .color(color.opacity(point.kind == "focus" ? 0.35 : 0.8)))
        context.stroke(dot, with: .color(color), lineWidth: point.kind == "focus" ? 1.5 : 0.8)
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(["conflict", "unrest", "coercion", "disaster", "shipping", "internet"], id: \.self) { kind in
                HStack(spacing: 4) {
                    Circle().fill(Self.color(kind)).frame(width: 7, height: 7)
                    Text(kind).font(.terminalSmall).foregroundStyle(Palette.text)
                }
            }
        }
        .padding(6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
        .padding(6)
    }
}
