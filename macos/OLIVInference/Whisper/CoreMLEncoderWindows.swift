import Foundation

/// Finite encoder shapes keep Core ML specialization bounded. A final decode
/// always uses Whisper's full 30-second window; previews round up to a shape
/// the artifact actually supports, including older full-window-only exports.
struct CoreMLEncoderWindows {
    let frames: [Int]

    init?(shapes: [[Int]], melBins: Int) {
        guard !shapes.isEmpty, shapes.allSatisfy({ shape in
            shape.count == 4 && shape[0] == 1 && shape[1] == melBins && shape[2] == 1
                && (50...3_000).contains(shape[3]) && shape[3].isMultiple(of: 2)
        }) else { return nil }
        let frames = Set(shapes.map { $0[3] }).sorted()
        guard frames.last == 3_000 else { return nil }
        self.frames = frames
    }

    func covering(_ wanted: Int) -> Int? {
        guard wanted > 0, wanted <= 3_000 else { return nil }
        return frames.first { $0 >= wanted }
    }

    static func acceptsOutputDescription(_ shape: [Int], dimensions: Int) -> Bool {
        // Core ML omits the static output shape when it depends on an
        // enumerated input. Every prediction is still checked against the
        // actual input window before its tensor crosses into MLX.
        shape.isEmpty || shape == [1, dimensions, 1, 1500]
    }
}
