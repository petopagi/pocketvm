import SwiftUI

enum Palette {
    static let apple = Color(red: 0.38, green: 0.78, blue: 0.36)
    static let windows = Color(red: 0.23, green: 0.51, blue: 0.96)
    static let ubuntu = Color(red: 0.95, green: 0.55, blue: 0.24)
    static let fedora = Color(red: 0.24, green: 0.43, blue: 0.71)
    static let running = Color(red: 0.33, green: 0.76, blue: 0.36)
    static let paused = Color(red: 0.13, green: 0.47, blue: 0.98)
    static let preparing = Color(red: 0.98, green: 0.62, blue: 0.16)
}

/// The system mark shown at the head of each row.
struct OSGlyph: View {
    let os: GuestOS
    let distro: String?
    var size: CGFloat = 28

    var body: some View {
        Group {
            switch os {
            case .macOS:
                Image(systemName: "apple.logo")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.04)
                    .foregroundStyle(Palette.apple)
            case .windows:
                WindowsMark().fill(Palette.windows)
                    .padding(size * 0.06)
            case .linux:
                switch distro {
                case "fedora":
                    Image(systemName: "f.circle")
                        .resizable()
                        .scaledToFit()
                        .fontWeight(.medium)
                        .foregroundStyle(Palette.fedora)
                default:
                    Sprout()
                        .stroke(Palette.ubuntu, style: StrokeStyle(lineWidth: size * 0.065, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// Four rounded panes.
struct WindowsMark: Shape {
    func path(in rect: CGRect) -> Path {
        let gap = rect.width * 0.09
        let side = (rect.width - gap) / 2
        let radius = side * 0.2
        var path = Path()
        for row in 0..<2 {
            for column in 0..<2 {
                let pane = CGRect(
                    x: rect.minX + CGFloat(column) * (side + gap),
                    y: rect.minY + CGFloat(row) * (side + gap),
                    width: side, height: side)
                path.addRoundedRect(in: pane, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
            }
        }
        return path
    }
}

/// A two-leaf seedling, for Linux machines.
struct Sprout: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        // Stem
        path.move(to: p(0.5, 0.94))
        path.addCurve(to: p(0.5, 0.52), control1: p(0.47, 0.8), control2: p(0.5, 0.64))
        // Left leaf
        path.move(to: p(0.5, 0.52))
        path.addCurve(to: p(0.06, 0.1), control1: p(0.48, 0.26), control2: p(0.3, 0.08))
        path.addCurve(to: p(0.5, 0.52), control1: p(0.02, 0.36), control2: p(0.2, 0.54))
        // Right leaf
        path.move(to: p(0.5, 0.52))
        path.addCurve(to: p(0.94, 0.1), control1: p(0.52, 0.26), control2: p(0.7, 0.08))
        path.addCurve(to: p(0.5, 0.52), control1: p(0.98, 0.36), control2: p(0.8, 0.54))
        return path
    }
}

/// Glyph plus the little status light in its corner.
struct MachineBadge: View {
    let machine: Machine
    var size: CGFloat = 28
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        OSGlyph(os: machine.config.os, distro: machine.config.distro, size: size)
            .overlay(alignment: .bottomTrailing) {
                if let color = statusColor {
                    Circle()
                        .fill(color)
                        .frame(width: size * 0.34, height: size * 0.34)
                        .padding(size * 0.06)
                        .background(Circle().fill(colorScheme == .dark ? Color(white: 0.16) : .white))
                        .offset(x: size * 0.16, y: size * 0.14)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: statusColor)
            .accessibilityElement()
            .accessibilityLabel("\(machine.config.os.title), \(statusLabel)")
    }

    private var statusLabel: String {
        switch machine.status {
        case .running: "running"
        case .starting: "starting"
        case .stopping: "shutting down"
        case .paused: "paused"
        case .suspended: "suspended"
        case .preparing: "setting up"
        case .stopped: "off"
        }
    }

    private var statusColor: Color? {
        switch machine.status {
        case .running, .starting, .stopping: Palette.running
        case .paused, .suspended: Palette.paused
        case .preparing: Palette.preparing
        case .stopped: nil
        }
    }
}
