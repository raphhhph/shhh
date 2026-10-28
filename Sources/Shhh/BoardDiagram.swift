import SwiftUI

/// Diagrams Joe draws on the study whiteboard while he answers: supply and demand with a shift,
/// a tax wedge, cost curves, a flow chart. The tutor writes a <diagram> tag with one drawing command
/// per line, in a 0–100 grid inside the axes:
///
///     <diagram title="A specific tax">
///     axes "Quantity" "Price"
///     line D 10,90 90,15
///     line S 10,15 90,80 blue
///     line "S + tax" 10,35 80,90 red dashed
///     arrow 60,55 54,66 red
///     point E1 50,48 x="Q1" y="P1"
///     area 30,62 47,62 47,40 30,40 orange "Tax revenue"
///     text 75,25 "Excess supply"
///     box 20,80 "Households"
///     </diagram>
///
/// Each line is drawn as it streams in, one stroke after another, so the diagram builds up while
/// Joe is still talking, the way a teacher draws on a board.
struct BoardDiagram: Equatable {
    enum Kind: String { case axes, line, arrow, point, area, text, box }

    struct Piece: Equatable {
        var kind: Kind
        var points: [CGPoint] = []
        var labels: [String] = []
        var color = ""
        var dashed = false
        /// A point's marks on the axes ("Q1" under it, "P1" beside the price axis).
        var xMark = ""
        var yMark = ""
        /// The line as written: with the title, what tells one drawn piece from another.
        var source = ""
        /// Not drawn: a curve on top of another one, or a label that repeats a curve's name.
        var hidden = false

        var label: String { labels.joined(separator: " ") }
    }

    var title: String
    var pieces: [Piece]

    /// The tag's body. While it's still streaming the last line may be half written, so it waits.
    static func parse(_ body: String, title: String, complete: Bool) -> BoardDiagram {
        var lines = body.components(separatedBy: "\n")
        if !complete { lines.removeLast() }
        return BoardDiagram(title: title, pieces: lines.compactMap(piece))
    }

    static func piece(_ line: String) -> Piece? {
        let tokens = tokens(line.trimmingCharacters(in: .whitespaces))
        guard let first = tokens.first, !first.quoted else { return nil }
        let aliases: [String: Kind] = ["curve": .line, "dot": .point, "shade": .area, "label": .text, "node": .box]
        guard let kind = Kind(rawValue: first.text.lowercased()) ?? aliases[first.text.lowercased()] else { return nil }
        var piece = Piece(kind: kind, source: line)
        for token in tokens.dropFirst() {
            if !token.quoted, let point = point(token.text) {
                piece.points.append(point)
            } else if !token.quoted, let equals = token.text.firstIndex(of: "=") {
                let key = token.text[..<equals].lowercased(), value = String(token.text[token.text.index(after: equals)...])
                switch key {
                case "x": piece.xMark = value
                case "y": piece.yMark = value
                case "color", "colour": piece.color = value.lowercased()
                default: piece.labels.append(value)
                }
            } else if !token.quoted, token.text.lowercased() == "dashed" {
                piece.dashed = true
            } else if !token.quoted, colors[token.text.lowercased()] != nil {
                piece.color = token.text.lowercased()
            } else {
                piece.labels.append(token.text)
            }
        }
        // "axes x=Quantity y=Price" says the same as "axes Quantity Price".
        if kind == .axes, piece.labels.isEmpty { piece.labels = [piece.xMark, piece.yMark] }
        let needed: [Kind: Int] = [.line: 2, .arrow: 2, .point: 1, .area: 3, .text: 1, .box: 1]
        guard piece.points.count >= needed[kind, default: 0] else { return nil }
        return piece
    }

    struct Token { var text: String; var quoted: Bool }

    /// Words, with "quoted labels" kept whole (also as key="a value").
    static func tokens(_ line: String) -> [Token] {
        var tokens: [Token] = [], current = "", inQuotes = false, wasQuoted = false
        for character in line {
            if character == "\"" || character == "“" || character == "”" {
                if inQuotes { tokens.append(Token(text: current, quoted: wasQuoted)); current = "" }
                else { wasQuoted = current.isEmpty }
                inQuotes.toggle()
            } else if character == " " && !inQuotes {
                if !current.isEmpty { tokens.append(Token(text: current, quoted: false)); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(Token(text: current, quoted: inQuotes && wasQuoted)) }
        return tokens
    }

    static func point(_ text: String) -> CGPoint? {
        let parts = text.split(separator: ",")
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
        return CGPoint(x: min(110, max(-10, x)), y: min(110, max(-10, y)))
    }

    static let colors: [String: Color] = [
        "black": .primary, "blue": .blue, "red": .red, "green": .green, "orange": .orange,
        "purple": .purple, "gray": .gray, "grey": .gray,
    ]
}

/// What's already been drawn (a card scrolled away and back isn't drawn twice), and when the next
/// stroke may start, so strokes go down one after another even when several arrive at once.
enum DiagramClock {
    static var drawn: Set<String> = []
    static var free = Date.distantPast
    /// For `--board-preview`: everything drawn at once.
    static var instant = false

    static func delay(for duration: Double) -> Double {
        let now = Date(), start = max(now, free)
        free = start.addingTimeInterval(duration)
        return start.timeIntervalSince(now)
    }
}

struct BoardDiagramView: View {
    let diagram: BoardDiagram
    /// Which card on the board this is, so the same diagram drawn again is drawn again.
    var key = ""
    /// Its card, with a way to draw on it (the board), or just the drawing (under the sketch pad).
    var onDrawOn: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if !diagram.title.isEmpty {
                    Text(diagram.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary)
                }
                Spacer()
                if let onDrawOn, !diagram.pieces.isEmpty {
                    Button("Draw on this", action: onDrawOn)
                        .font(.system(size: 12.5, weight: .medium))
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .help("Copy this diagram onto your sketch pad, add your shift or labels, and send it with your answer")
                }
            }
            DiagramDrawing(diagram: diagram, key: key).frame(height: 320)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

/// The drawing alone, filling its frame. Not animated: under the sketch pad, and in the picture sent to Joe.
struct DiagramDrawing: View {
    let diagram: BoardDiagram
    var key = ""
    var animated = true

    var body: some View {
        GeometryReader { geometry in
            // Room for the price axis's marks on the left, the curve labels on the right.
            let plot = CGRect(x: 56, y: 22, width: max(100, geometry.size.width - 56 - 70), height: max(100, geometry.size.height - 22 - 40))
            let pieces = DiagramLayout.tidy(diagram.pieces)
            let spots = DiagramLayout.labels(pieces, in: plot, width: geometry.size.width)
            ZStack(alignment: .topLeading) {
                ForEach(Array(pieces.enumerated()), id: \.offset) { index, piece in
                    if !piece.hidden {
                        DiagramPiece(piece: piece, plot: plot, key: "\(key)#\(diagram.title)#\(index)#\(piece.source)", animated: animated,
                                     labelAt: spots[index])
                    }
                }
            }
        }
    }
}

/// One command of the diagram, drawn in with a stroke and its labels fading in.
private struct DiagramPiece: View {
    let piece: BoardDiagram.Piece
    let plot: CGRect
    let key: String
    /// Where its movable label goes (a curve's name, a point's, an arrow's, a text), from the layout.
    var labelAt: CGPoint?
    @State private var progress: CGFloat

    init(piece: BoardDiagram.Piece, plot: CGRect, key: String, animated: Bool, labelAt: CGPoint? = nil) {
        self.piece = piece
        self.plot = plot
        self.key = key
        self.labelAt = labelAt
        // An image renderer never calls onAppear, so a still drawing starts finished.
        _progress = State(initialValue: animated && !DiagramClock.instant ? 0 : 1)
    }

    private var color: Color { BoardDiagram.colors[piece.color] ?? .primary }

    private func at(_ p: CGPoint) -> CGPoint {
        CGPoint(x: plot.minX + p.x / 100 * plot.width, y: plot.maxY - p.y / 100 * plot.height)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch piece.kind {
            case .area:
                PiecePath(path: polygon).fill(color.opacity(0.22 * Double(progress)))
            case .text, .box:
                EmptyView()
            default:
                PiecePath(path: stroke).trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: piece.kind == .axes ? 1.8 : 2.4, lineCap: .round, lineJoin: .round,
                                                      dash: piece.dashed ? [7, 5] : []))
            }
            if piece.kind == .point {
                PiecePath(path: guides).trim(from: 0, to: progress)
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            labels.opacity(Double(progress))
        }
        .onAppear(perform: draw)
    }

    private func draw() {
        guard progress < 1, !DiagramClock.drawn.contains(key) else { progress = 1; return }
        DiagramClock.drawn.insert(key)
        let durations: [BoardDiagram.Kind: Double] = [.text: 0.3, .box: 0.3, .point: 0.4, .area: 0.4]
        let duration = durations[piece.kind] ?? 0.7
        withAnimation(.easeInOut(duration: duration).delay(DiagramClock.delay(for: duration))) { progress = 1 }
    }

    // MARK: Paths

    private var stroke: Path {
        var path = Path()
        let points = piece.points.map(at)
        switch piece.kind {
        case .axes:
            path.move(to: CGPoint(x: plot.minX, y: plot.minY))
            path.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
            path.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        case .point:
            if let p = points.first { path.addEllipse(in: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)) }
        case .arrow:
            guard let a = points.first, let b = points.last else { break }
            path.move(to: a)
            path.addLine(to: b)
            let angle = atan2(b.y - a.y, b.x - a.x)
            for side in [-1.0, 1.0] {
                path.move(to: b)
                path.addLine(to: CGPoint(x: b.x - 10 * cos(angle + side * .pi / 7), y: b.y - 10 * sin(angle + side * .pi / 7)))
            }
        default:
            path = Self.smooth(points)
        }
        return path
    }

    private var polygon: Path {
        var path = Path()
        path.addLines(piece.points.map(at))
        path.closeSubpath()
        return path
    }

    /// From a point down to the quantity axis and across to the price axis, where its marks go.
    private var guides: Path {
        var path = Path()
        guard let p = piece.points.first.map(at) else { return path }
        if !piece.xMark.isEmpty { path.move(to: p); path.addLine(to: CGPoint(x: p.x, y: plot.maxY)) }
        if !piece.yMark.isEmpty { path.move(to: p); path.addLine(to: CGPoint(x: plot.minX, y: p.y)) }
        return path
    }

    /// Two points: a straight line. More: a smooth curve through them all (Catmull–Rom).
    static func smooth(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else { points.dropFirst().forEach { path.addLine(to: $0) }; return path }
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
            path.addCurve(to: p2, control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        return path
    }

    // MARK: Labels

    @ViewBuilder
    private var labels: some View {
        let points = piece.points.map(at)
        switch piece.kind {
        case .axes:
            let x = piece.labels.first ?? "", y = piece.labels.dropFirst().first ?? ""
            tag(y, bold: true).position(x: plot.minX, y: plot.minY - 12)
            tag(x, bold: true).position(x: plot.maxX, y: plot.maxY + 16)
            tag("0").position(x: plot.minX - 10, y: plot.maxY + 10)
        case .line:
            if let end = points.last, !piece.label.isEmpty {
                tag(piece.label, bold: true, color: color).fixedSize()
                    .position(labelAt ?? CGPoint(x: end.x + 8 + CGFloat(piece.label.count) * 3.6, y: end.y - 6))
            }
        case .arrow:
            if let end = points.last, !piece.label.isEmpty {
                tag(piece.label, color: color).fixedSize().readable().position(labelAt ?? CGPoint(x: end.x, y: end.y - 12))
            }
        case .point:
            if let p = points.first {
                if !piece.label.isEmpty {
                    tag(piece.label, bold: true).fixedSize().position(labelAt ?? CGPoint(x: p.x + 10 + CGFloat(piece.label.count) * 3, y: p.y - 11))
                }
                if !piece.xMark.isEmpty { tag(piece.xMark).fixedSize().position(x: p.x, y: plot.maxY + 14) }
                if !piece.yMark.isEmpty { tag(piece.yMark).fixedSize().position(x: plot.minX - 8 - CGFloat(piece.yMark.count) * 3.4, y: p.y) }
            }
        case .area:
            if !points.isEmpty, !piece.label.isEmpty {
                let centre = CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count), y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
                tag(piece.label, size: 11).fixedSize().readable().position(labelAt ?? centre)
            }
        case .text:
            if let p = points.first { tag(piece.label, color: color).fixedSize().readable().position(labelAt ?? p) }
        case .box:
            if let p = points.first {
                tag(piece.label, bold: true).fixedSize()
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(color, lineWidth: 1.5))
                    .position(p)
            }
        }
    }

    private func tag(_ text: String, bold: Bool = false, size: CGFloat = 12.5, color: Color = .primary) -> some View {
        Text(text).font(.system(size: size, weight: bold ? .semibold : .regular)).foregroundStyle(color)
    }
}

private extension View {
    /// Text over curves and shading: on a patch of the page, so a line crossing it doesn't cut it.
    func readable() -> some View {
        padding(.horizontal, 4).padding(.vertical, 1)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.9), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

private struct PiecePath: Shape {
    let path: Path
    func path(in rect: CGRect) -> Path { path }
}

// MARK: - Layout

/// Tidies what the tutor wrote before it's drawn, and places the labels so none lands on another
/// label or across a curve:
/// - two curves drawn on top of each other (S + tax over MSC) are drawn once, with one label
///   ("MSC = S + tax");
/// - a text that only repeats a curve's name is dropped;
/// - a shaded rectangle that nearly reaches the price axis (tax revenue, spending) starts on it.
enum DiagramLayout {
    typealias Piece = BoardDiagram.Piece

    static func tidy(_ pieces: [Piece]) -> [Piece] {
        var pieces = pieces
        // Coincident curves: the first one drawn stays, with both names.
        for i in pieces.indices where pieces[i].kind == .line && !pieces[i].hidden {
            for j in pieces.indices where j > i && pieces[j].kind == .line && !pieces[j].hidden {
                guard coincide(pieces[i].points, pieces[j].points) else { continue }
                let first = pieces[i].label, second = pieces[j].label
                if !second.isEmpty, !names(first).contains(normal(second)) {
                    pieces[i].labels = [first.isEmpty ? second : "\(first) = \(second)"]
                }
                pieces[j].hidden = true
            }
        }
        // Texts that repeat a curve's name (or an earlier text).
        var seen = Set(pieces.filter { $0.kind == .line && !$0.hidden }.flatMap { names($0.label) })
        for i in pieces.indices where pieces[i].kind == .text {
            let name = normal(pieces[i].label)
            if seen.contains(name) { pieces[i].hidden = true } else { seen.insert(name) }
        }
        // Shaded areas that start just off the price axis start on it.
        for i in pieces.indices where pieces[i].kind == .area {
            guard let left = pieces[i].points.map(\.x).min(), left > 0, left <= 12 else { continue }
            pieces[i].points = pieces[i].points.map { $0.x == left ? CGPoint(x: 0, y: $0.y) : $0 }
        }
        return pieces
    }

    /// "MSC = S + tax" is called "msc" and "s+tax".
    private static func names(_ label: String) -> Set<String> {
        Set(label.components(separatedBy: "=").map(normal).filter { !$0.isEmpty })
    }

    private static func normal(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    /// Every point of each curve lies on the other (within 2.5 of the 100-wide grid).
    private static func coincide(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
        a.count >= 2 && b.count >= 2 && a.allSatisfy { distance($0, to: b) <= 2.5 } && b.allSatisfy { distance($0, to: a) <= 2.5 }
    }

    /// From a point to a polyline, extended a little past its ends (two lines drawn over different spans still coincide).
    private static func distance(_ p: CGPoint, to line: [CGPoint]) -> CGFloat {
        zip(line, line.dropFirst()).map { a, b in
            let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
            guard length > 0 else { return hypot(p.x - a.x, p.y - a.y) }
            let t = max(-0.5, min(1.5, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
            return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
        }.min() ?? .infinity
    }

    /// Centres for the movable labels, by piece: curve names first, then points, arrows, shaded
    /// areas and texts, each at the first nearby spot clear of the labels already placed and of the curves.
    static func labels(_ pieces: [Piece], in plot: CGRect, width: CGFloat) -> [Int: CGPoint] {
        func at(_ p: CGPoint) -> CGPoint { CGPoint(x: plot.minX + p.x / 100 * plot.width, y: plot.maxY - p.y / 100 * plot.height) }
        func size(_ text: String, _ font: CGFloat) -> CGSize { CGSize(width: CGFloat(text.count) * font * 0.58 + 10, height: font + 6) }
        func rect(_ centre: CGPoint, _ size: CGSize) -> CGRect {
            CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
        }
        let visible = pieces.filter { !$0.hidden }
        // Curves as straight segments on screen, and the axes.
        var segments: [(CGPoint, CGPoint)] = visible.filter { $0.kind == .line || $0.kind == .arrow }.flatMap { piece in
            let points = piece.points.map(at)
            return Array(zip(points, points.dropFirst()))
        }
        if visible.contains(where: { $0.kind == .axes }) {
            segments += [(CGPoint(x: plot.minX, y: plot.minY), CGPoint(x: plot.minX, y: plot.maxY)),
                         (CGPoint(x: plot.minX, y: plot.maxY), CGPoint(x: plot.maxX, y: plot.maxY))]
        }
        // The fixed labels: the axes' names and the marks on them.
        var placed: [CGRect] = []
        for piece in visible {
            if piece.kind == .axes {
                placed.append(rect(CGPoint(x: plot.minX, y: plot.minY - 12), size(piece.labels.dropFirst().first ?? "", 12.5)))
                placed.append(rect(CGPoint(x: plot.maxX, y: plot.maxY + 16), size(piece.labels.first ?? "", 12.5)))
            }
            if piece.kind == .point, let p = piece.points.first.map(at) {
                if !piece.xMark.isEmpty { placed.append(rect(CGPoint(x: p.x, y: plot.maxY + 14), size(piece.xMark, 12.5))) }
                if !piece.yMark.isEmpty { placed.append(rect(CGPoint(x: plot.minX - 8 - CGFloat(piece.yMark.count) * 3.4, y: p.y), size(piece.yMark, 12.5))) }
            }
        }
        func crossesCurve(_ box: CGRect) -> Bool {
            let inner = box.insetBy(dx: 2, dy: 2)
            return segments.contains { a, b in
                // Sampled along the segment: enough for labels a dozen points tall.
                let steps = max(2, Int(hypot(b.x - a.x, b.y - a.y) / 4))
                return (0...steps).contains { step in
                    let t = CGFloat(step) / CGFloat(steps)
                    return inner.contains(CGPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y)))
                }
            }
        }
        func clashes(_ box: CGRect, curves: Bool) -> Int {
            let labels: Int = placed.filter { $0.intersects(box) }.count * 2
            let curve: Int = curves && crossesCurve(box) ? 1 : 0
            let outside: Int = box.minX < 0 || box.maxX > width + 60 ? 3 : 0
            return labels + curve + outside
        }
        var spots: [Int: CGPoint] = [:]
        let order: [BoardDiagram.Kind] = [.line, .point, .arrow, .area, .text]
        for kind in order {
            for (index, piece) in pieces.enumerated() where piece.kind == kind && !piece.hidden && !piece.label.isEmpty {
                let points = piece.points.map(at)
                let font: CGFloat = kind == .area ? 11 : 12.5
                let box = size(piece.label, font)
                var preferred: CGPoint
                var candidates: [CGSize]
                switch kind {
                case .line:
                    // At the right end; up or down from it when another curve's name is there.
                    guard let end = points.last else { continue }
                    preferred = CGPoint(x: end.x + 8 + box.width / 2 - 5, y: end.y - 6)
                    if preferred.x + box.width / 2 > width { preferred = CGPoint(x: end.x - box.width / 2, y: end.y - 16) }
                    candidates = [0, -16, 16, -32, 32, -48].map { CGSize(width: 0, height: $0) }
                case .point:
                    guard let p = points.first else { continue }
                    preferred = CGPoint(x: p.x + 10 + box.width / 2 - 5, y: p.y - 11)
                    candidates = [CGSize(width: 0, height: 0), CGSize(width: 0, height: 22), CGSize(width: -box.width - 10, height: 0),
                                  CGSize(width: -box.width - 10, height: 22)]
                case .arrow:
                    guard let end = points.last else { continue }
                    preferred = CGPoint(x: end.x, y: end.y - 12)
                    candidates = Self.around
                case .area:
                    guard !points.isEmpty else { continue }
                    preferred = CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count), y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
                    candidates = Self.around
                default:
                    guard let p = points.first else { continue }
                    preferred = p
                    candidates = Self.around
                }
                // Shaded areas' labels sit on their shading, so only other labels count against them there.
                let curves = kind != .line && kind != .area
                let best = candidates.map { offset in CGPoint(x: preferred.x + offset.width, y: preferred.y + offset.height) }
                    .enumerated()
                    .min { a, b in
                        let ca = clashes(rect(a.element, box), curves: curves), cb = clashes(rect(b.element, box), curves: curves)
                        return ca != cb ? ca < cb : a.offset < b.offset
                    }?.element ?? preferred
                spots[index] = best
                placed.append(rect(best, box))
            }
        }
        return spots
    }

    /// Nearby spots to try, nearest first.
    private static let around: [CGSize] = [
        CGSize(width: 0, height: 0), CGSize(width: 0, height: -18), CGSize(width: 0, height: 18),
        CGSize(width: 28, height: -18), CGSize(width: -28, height: 18), CGSize(width: 28, height: 18), CGSize(width: -28, height: -18),
        CGSize(width: 0, height: -34), CGSize(width: 0, height: 34), CGSize(width: 48, height: 0), CGSize(width: -48, height: 0),
    ]
}
