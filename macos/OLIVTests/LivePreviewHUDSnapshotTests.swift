// Offscreen renders of the recording HUD with live-preview text (#26), in light
// and dark mode, for checking that Thai vowels and tone marks never clip and
// that the newest words stay visible. Nothing is shown on screen; the sample
// sentences are made up.
//
// Skipped unless OLIV_HUD_SNAPSHOT_DIR is set:
//
//   TEST_RUNNER_OLIV_HUD_SNAPSHOT_DIR=/tmp/oliv-hud xcodebuild test -project macos/OLIV.xcodeproj \
//     -scheme OLIV -destination 'platform=macOS,arch=arm64' \
//     -only-testing:OLIVTests/LivePreviewHUDSnapshotTests

import AppKit
import SwiftUI
import XCTest
@testable import OLIV

@MainActor
final class LivePreviewHUDSnapshotTests: XCTestCase {
    static let samples: [(name: String, text: String)] = [
        ("thai", "พรุ่งนี้เช้าเก้าโมงประชุมทีมที่ห้องใหญ่ ช่วยเตรียมสไลด์เรื่องงบไตรมาสสี่ด้วยนะครับ"),
        ("mixed", "ช่วย deploy เวอร์ชันใหม่ขึ้น staging แล้วเช็ค log ใน Grafana ให้หน่อย ถ้า error rate เกินห้าเปอร์เซ็นต์ให้ rollback"),
        ("stacked-marks", "ญี่ปุ่นกี่ฤดูที่ผู้ใหญ่ปู่ย่าเล่าสู่กันฟัง น้ำค้างแข็งตั้งแต่เดือนสิบเอ็ด ฤๅษีก็ยังจำได้"),
        ("short", "สวัสดีครับ"),
        ("english", "Let's move the standup to ten thirty tomorrow and share the quarterly numbers before lunch"),
    ]

    private var outputDir: URL!

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["OLIV_HUD_SNAPSHOT_DIR"], !dir.isEmpty else {
            throw XCTSkip("set OLIV_HUD_SNAPSHOT_DIR to render the HUD")
        }
        outputDir = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    }

    private func model(phase: HUDPhase, text: String) -> HUDModel {
        let model = HUDModel()
        model.engineID = SidecarClient.defaultEngine
        for i in 0..<HUDModel.barCount {
            model.push(level: Float(0.35 + 0.3 * sin(Double(i) * 0.7)))
        }
        model.phase = phase
        model.previewText = LivePreview.tail(text)
        return model
    }

    private func render(_ model: HUDModel, scheme: ColorScheme, name: String) throws {
        let backdrop = scheme == .dark ? Color(white: 0.16) : Color(white: 0.9)
        let view = RecordingHUDView(model: model)
            .background(backdrop)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: outputDir.appendingPathComponent("hud-\(name)-\(scheme == .dark ? "dark" : "light").png"))
    }

    func testRenderHUD() throws {
        for scheme in [ColorScheme.light, .dark] {
            try render(model(phase: .recording, text: ""), scheme: scheme, name: "recording")
            try render(model(phase: .processing, text: ""), scheme: scheme, name: "processing")
            for sample in Self.samples {
                try render(model(phase: .recording, text: sample.text), scheme: scheme, name: "preview-\(sample.name)")
            }
        }
    }
}
