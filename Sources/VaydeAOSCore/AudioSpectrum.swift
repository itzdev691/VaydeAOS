import Foundation

/// Logarithmic frequency bands from real PCM samples, normalized over -72...0 dBFS.
public struct AudioSpectrum: Sendable {
    public let bands: [Double]
    public let rms: Double

    public init(samples: [Float], sampleRate: Double, bandCount: Int = 72) {
        let count = max(1, min(256, bandCount))
        guard sampleRate.isFinite, sampleRate > 0, samples.count >= 32 else {
            bands = .init(repeating: 0, count: count); rms = 0; return
        }
        var size = 32
        while size * 2 <= min(samples.count, 2048) { size *= 2 }
        let input = samples.suffix(size).map { $0.isFinite ? Double($0) : 0 }
        rms = min(1, sqrt(input.reduce(0) { $0 + $1 * $1 } / Double(size)))
        var real = input.enumerated().map { i, value in
            value * (0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(size - 1)))
        }
        var imaginary = [Double](repeating: 0, count: size)
        var j = 0
        for i in 1..<size {
            var bit = size >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j ^= bit
            if i < j { real.swapAt(i, j); imaginary.swapAt(i, j) }
        }
        var length = 2
        while length <= size {
            let angle = -2 * Double.pi / Double(length)
            for start in stride(from: 0, to: size, by: length) {
                for offset in 0..<(length / 2) {
                    let c = cos(angle * Double(offset)), s = sin(angle * Double(offset))
                    let a = start + offset, b = a + length / 2
                    let x = real[b] * c - imaginary[b] * s
                    let y = real[b] * s + imaginary[b] * c
                    real[b] = real[a] - x; imaginary[b] = imaginary[a] - y
                    real[a] += x; imaginary[a] += y
                }
            }
            length *= 2
        }
        let low = min(40, sampleRate / 8), high = min(18000, sampleRate / 2)
        bands = (0..<count).map { band in
            let lower = low * pow(high / low, Double(band) / Double(count))
            let upper = low * pow(high / low, Double(band + 1) / Double(count))
            let first = max(1, min(size / 2 - 1, Int(lower * Double(size) / sampleRate)))
            let last = max(first, min(size / 2 - 1, Int(ceil(upper * Double(size) / sampleRate))))
            let peak = (first...last).map { hypot(real[$0], imaginary[$0]) * 4 / Double(size) }.max() ?? 0
            return min(1, max(0, (20 * log10(max(peak, 0.0000001)) + 72) / 72))
        }
    }
}
