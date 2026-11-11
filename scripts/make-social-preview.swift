// Draws the GitHub social preview (1280x640) to scripts/social-preview.png.
// Upload it in the repo's Settings > General > Social preview.
// Run from the repo root after scripts/make-icon.swift: swift scripts/make-social-preview.swift
import AppKit
import SwiftUI

struct Preview: View {
    let icon: NSImage

    var body: some View {
        HStack(spacing: 64) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 300, height: 300)
            VStack(alignment: .leading, spacing: 18) {
                Text("QuickPass")
                    .font(.system(size: 92, weight: .bold))
                    .foregroundStyle(.white)
                Text("A keyboard shortcut for\nApple Passwords on the Mac")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineSpacing(6)
                Text("⌃⌥Space  ·  search  ·  ⌘C")
                    .font(.system(size: 30, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 10)
            }
        }
        .frame(width: 1280, height: 640)
        .background(LinearGradient(colors: [Color(red: 0.09, green: 0.10, blue: 0.20), Color(red: 0.16, green: 0.12, blue: 0.38)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

@MainActor func render() throws {
    guard let icon = NSImage(contentsOfFile: "scripts/icon-preview.png") else { fatalError("Run scripts/make-icon.swift first") }
    let renderer = ImageRenderer(content: Preview(icon: icon))
    renderer.scale = 1
    guard let cg = renderer.cgImage else { fatalError("render failed") }
    try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "scripts/social-preview.png"))
}

MainActor.assumeIsolated { try! render() }
