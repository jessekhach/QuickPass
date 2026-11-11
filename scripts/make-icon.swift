// Draws the app icon and writes Resources/Assets.xcassets/AppIcon.appiconset.
// Run from the repo root: swift scripts/make-icon.swift
import AppKit
import SwiftUI

struct Icon: View {
    var body: some View {
        ZStack {
            // Apple's macOS icon grid: an 824 pt rounded square centered on a 1024 canvas.
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.55, blue: 1.0), Color(red: 0.29, green: 0.20, blue: 0.86)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center))
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.3), radius: 18, y: 12)

            // A search bar with a key in it: the app in one picture.
            Capsule()
                .fill(.white.opacity(0.95))
                .frame(width: 600, height: 196)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
            HStack(spacing: 40) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 150, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [Color(red: 0.36, green: 0.55, blue: 1.0), Color(red: 0.29, green: 0.20, blue: 0.86)],
                                                    startPoint: .leading, endPoint: .trailing))
                HStack(spacing: 18) {
                    ForEach(0..<4, id: \.self) { _ in
                        Circle().fill(Color(white: 0.6)).frame(width: 36, height: 36)
                    }
                }
            }
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor func render() throws {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    guard let cg = renderer.cgImage else { fatalError("render failed") }
    let rep = NSBitmapImageRep(cgImage: cg)
    let master = rep.representation(using: .png, properties: [:])!

    let dir = URL(fileURLWithPath: "Resources/Assets.xcassets/AppIcon.appiconset")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try master.write(to: dir.appendingPathComponent("icon_1024.png"))

    var images: [[String: String]] = []
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = points * scale
            let name = "icon_\(points)@\(scale)x.png"
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
            task.arguments = ["-z", "\(pixels)", "\(pixels)", dir.appendingPathComponent("icon_1024.png").path,
                              "--out", dir.appendingPathComponent(name).path]
            task.standardOutput = FileHandle.nullDevice
            try task.run()
            task.waitUntilExit()
            images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
        }
    }
    try FileManager.default.removeItem(at: dir.appendingPathComponent("icon_1024.png"))
    try? master.write(to: URL(fileURLWithPath: "scripts/icon-preview.png"))
    let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
    try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        .write(to: dir.appendingPathComponent("Contents.json"))
    let catalog = ["info": ["version": 1, "author": "xcode"]]
    try JSONSerialization.data(withJSONObject: catalog, options: .prettyPrinted)
        .write(to: URL(fileURLWithPath: "Resources/Assets.xcassets/Contents.json"))
}

MainActor.assumeIsolated { try! render() }
