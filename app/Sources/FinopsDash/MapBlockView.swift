import FinopsCore
import MapKit
import SwiftUI

/// World map of events: colour = type, size = severity. Clicking a point runs its command
/// (LINK <entity>) or opens its source in the reader.
public struct MapBlockView: View {
    let block: GatewayDocument.MapBlock
    let run: (String) -> Void
    var height: CGFloat? = 420
    /// Frame the whole world (WORLD's main map) rather than the populated band.
    var wholeWorld = false

    @State private var selected: GatewayDocument.MapBlock.Point?

    public init(block: GatewayDocument.MapBlock, run: @escaping (String) -> Void, height: CGFloat? = 420, wholeWorld: Bool = false) {
        self.block = block
        self.run = run
        self.height = height
        self.wholeWorld = wholeWorld
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
            ZStack(alignment: .bottomLeading) {
                Map(initialPosition: .rect(wholeWorld ? MKMapRect.world
                                           : MKMapRect(x: 0, y: MKMapSize.world.height * 0.12,
                                                       width: MKMapSize.world.width, height: MKMapSize.world.height * 0.66))) {
                    ForEach(block.points) { point in
                        Annotation("", coordinate: CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon), anchor: .center) {
                            dot(point)
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
                .environment(\.colorScheme, .dark)
                legend
            }
            .frame(height: height)
            .frame(maxHeight: height == nil ? .infinity : nil)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            if let selected {
                HStack(alignment: .firstTextBaseline) {
                    Circle().fill(Self.color(selected.kind)).frame(width: 8, height: 8)
                    Text(selected.label).font(.terminalSmall).foregroundStyle(Palette.text)
                    if let detail = selected.detail { Text(detail).font(.terminalSmall).foregroundStyle(Palette.muted) }
                }
            }
        }
    }

    private func dot(_ point: GatewayDocument.MapBlock.Point) -> some View {
        let size = CGFloat(6 + 5 * (point.severity ?? 1))
        let color = Self.color(point.kind)
        return Circle()
            .fill(color.opacity(0.75))
            .overlay(Circle().stroke(color, lineWidth: 1))
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.6), radius: point.severity == 3 ? 6 : 0)
            #if !os(tvOS)
            .onHover { inside in if inside { selected = point } }
            .help(point.label)
            #endif
            .onTapGesture {
                selected = point
                if let cmd = point.cmd { run(cmd) } else if let url = point.url { run("READ \(url)") }
            }
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
