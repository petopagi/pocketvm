// Renders PocketVM's app icon. Run: swift Support/Icon/render.swift <out.png>
import AppKit
import SwiftUI

struct Icon: View {
    let top = Color(red: 0.42, green: 0.40, blue: 0.98)
    let bottom = Color(red: 0.22, green: 0.18, blue: 0.70)

    var body: some View {
        ZStack {
            // macOS icon grid: 824 pt tile on a 1024 canvas.
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
                .overlay(
                    // Soft top sheen, as on system icons.
                    RoundedRectangle(cornerRadius: 186, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: .center))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 186, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 3)
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.28), radius: 20, y: 12)

            // The machine behind…
            RoundedRectangle(cornerRadius: 58, style: .continuous)
                .fill(.white.opacity(0.32))
                .frame(width: 400, height: 300)
                .offset(x: -54, y: -58)

            // …and the one in front, with its window controls.
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 58, style: .continuous)
                    .fill(.white)
                    .shadow(color: bottom.opacity(0.45), radius: 24, y: 12)
                HStack(spacing: 16) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(bottom.opacity(0.28)).frame(width: 28, height: 28)
                    }
                }
                .padding(.leading, 42)
                .padding(.top, 40)
            }
            .frame(width: 400, height: 300)
            .offset(x: 54, y: 52)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor func render() {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    guard let image = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("render failed") }
    try! png.write(to: URL(filePath: CommandLine.arguments[1]))
}
MainActor.assumeIsolated { render() }
