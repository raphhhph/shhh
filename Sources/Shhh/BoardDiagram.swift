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
                    Label(diagram.title, systemImage: "chart.xyaxis.line").font(.system(size: 13, weight: .bold)).foregroundStyle(.secondary)
                }
                Spacer()
                if let onDrawOn, !diagram.pieces.isEmpty {
                    Button(action: onDrawOn) { Label("Draw on this", systemImage: "pencil.tip") }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help("Copy this diagram onto your sketch pad, add your shift or labels, and send it with your answer")
                }
            }
            DiagramDrawing(diagram: diagram, key: key).frame(height: 320)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
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
            ZStack(alignment: .topLeading) {
                ForEach(Array(diagram.pieces.enumerated()), id: \.offset) { index, piece in
                    DiagramPiece(piece: piece, plot: plot, key: "\(key)#\(diagram.title)#\(index)#\(piece.source)", animated: animated)
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
    @State private var progress: CGFloat

    init(piece: BoardDiagram.Piece, plot: CGRect, key: String, animated: Bool) {
        self.piece = piece
        self.plot = plot
        self.key = key
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
                tag(piece.label, bold: true, color: color).fixedSize().position(x: end.x + 8 + CGFloat(piece.label.count) * 3.6, y: end.y - 6)
            }
        case .arrow:
            if let end = points.last, !piece.label.isEmpty { tag(piece.label, color: color).fixedSize().position(x: end.x, y: end.y - 12) }
        case .point:
            if let p = points.first {
                if !piece.label.isEmpty { tag(piece.label, bold: true).fixedSize().position(x: p.x + 10 + CGFloat(piece.label.count) * 3, y: p.y - 11) }
                if !piece.xMark.isEmpty { tag(piece.xMark).fixedSize().position(x: p.x, y: plot.maxY + 14) }
                if !piece.yMark.isEmpty { tag(piece.yMark).fixedSize().position(x: plot.minX - 8 - CGFloat(piece.yMark.count) * 3.4, y: p.y) }
            }
        case .area:
            if !points.isEmpty, !piece.label.isEmpty {
                let centre = CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count), y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
                tag(piece.label, size: 11).fixedSize().readable().position(centre)
            }
        case .text:
            if let p = points.first { tag(piece.label, color: color).fixedSize().readable().position(p) }
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
