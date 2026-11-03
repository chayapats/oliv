// Live previews only (#46): how long an encode, and when a decode stops. No
// MLX here, so the app's tests compile this file too.
import Foundation

enum PreviewDecodeGuard {
    static let sampleRate = 16_000
    static let hopLength = 160
    /// Whisper's window: 30 s, 3000 mel frames.
    static let windowFrames = 3_000

    /// Encoder input frames for `content` frames of audio: max(audio + tail,
    /// floor), rounded up to a whole half second (the conv stem halves it;
    /// whole steps keep the number of distinct shapes small), at most the
    /// 30 s window.
    static func encoderFrames(content: Int, floorSeconds: Double, tailSeconds: Double) -> Int {
        let perSecond = Double(sampleRate / hopLength)
        let wanted = max(Double(content) + tailSeconds * perSecond, floorSeconds * perSecond)
        let step = sampleRate / hopLength / 2
        return min(windowFrames, max(step, Int((wanted / Double(step)).rounded(.up)) * step))
    }

    /// A short window can make Whisper say the sentence again (and again): a
    /// run of this many text tokens seen earlier in the same decode ends it.
    static let repeatSpan = 10
    /// Tokens allowed per second of audio, plus a fixed allowance: well above
    /// what speech needs (Thai and English previews measured under 21 tokens
    /// per second for 2 s or more of audio), so only a runaway decode hits it.
    static let tokensPerSecond = 25.0
    static let tokenAllowance = 24

    static func tokenLimit(audioFrames: Int) -> Int {
        let seconds = Double(audioFrames * hopLength) / Double(sampleRate)
        return tokenAllowance + Int((seconds * tokensPerSecond).rounded(.up))
    }

    /// Where the decode started saying again what it already said: the index
    /// in `tokens` where the last `span` text tokens (timestamps skipped)
    /// begin, when that run appeared earlier too. nil when there is no repeat.
    static func repeatStart(_ tokens: [Int], timestampBegin: Int, span: Int = repeatSpan) -> Int? {
        guard span > 0, let last = tokens.last, last < timestampBegin else { return nil }
        var text: [Int] = [], positions: [Int] = []
        for (index, token) in tokens.enumerated() where token < timestampBegin {
            text.append(token); positions.append(index)
        }
        guard text.count >= 2 * span else { return nil }
        let tail = text[(text.count - span)...]
        for start in 0...(text.count - 2 * span) where text[start..<(start + span)].elementsEqual(tail) {
            return positions[text.count - span]
        }
        return nil
    }
}
