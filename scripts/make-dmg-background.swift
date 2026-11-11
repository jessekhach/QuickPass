// Draws the DMG window background at 1x and 2x and combines them into
// Resources/dmg-background.tiff, which release.sh uses.
// Run from the repo root: swift scripts/make-dmg-background.swift
import AppKit
import SwiftUI

/// 660×400 window. The app icon sits at (180, 190) and the Applications folder at (480, 190),
/// matching the positions in scripts/release.sh.
struct Background: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.95, green: 0.96, blue: 1.0), Color(red: 0.88, green: 0.89, blue: 0.99)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 0) {
                Text("Drag QuickPass to Applications")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(red: 0.24, green: 0.22, blue: 0.45))
                    .padding(.top, 44)
                Spacer()
            }
            Image(systemName: "arrow.right")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [Color(red: 0.36, green: 0.55, blue: 1.0), Color(red: 0.29, green: 0.20, blue: 0.86)],
                                                startPoint: .leading, endPoint: .trailing))
                .offset(y: -10)
        }
        .frame(width: 660, height: 400)
    }
}

@MainActor func render(scale: CGFloat, to path: String) throws {
    let renderer = ImageRenderer(content: Background())
    renderer.scale = scale
    guard let cg = renderer.cgImage else { fatalError("render failed") }
    let rep = NSBitmapImageRep(cgImage: cg)
    rep.size = NSSize(width: 660, height: 400) // marks the 2x image as Retina
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

MainActor.assumeIsolated {
    let dir = FileManager.default.temporaryDirectory
    let one = dir.appendingPathComponent("dmg-bg.png").path
    let two = dir.appendingPathComponent("dmg-bg@2x.png").path
    try! render(scale: 1, to: one)
    try! render(scale: 2, to: two)
    let tiffutil = Process()
    tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
    tiffutil.arguments = ["-cathidpicheck", one, two, "-out", "Resources/dmg-background.tiff"]
    try! tiffutil.run()
    tiffutil.waitUntilExit()
}
