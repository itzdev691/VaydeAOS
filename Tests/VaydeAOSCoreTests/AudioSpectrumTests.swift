import Foundation
import Testing
@testable import VaydeAOSCore

@Test func spectrumSilenceAndInvalidInputStayFlat() {
    let silence = AudioSpectrum(samples: [Float](repeating: 0, count: 2048), sampleRate: 48000)
    #expect(silence.rms == 0)
    #expect(silence.bands.count == 72)
    #expect(silence.bands.allSatisfy { $0 == 0 })
    #expect(AudioSpectrum(samples: [], sampleRate: 0).bands.allSatisfy { $0 == 0 })
    let invalid = AudioSpectrum(samples: [Float](repeating: .nan, count: 2048), sampleRate: 48000)
    #expect(invalid.bands.allSatisfy { $0 == 0 })
}

@Test func spectrumLocatesToneAndMeasuresLevel() {
    let samples = (0..<2048).map { Float(0.5 * sin(2 * .pi * 1000 * Double($0) / 48000)) }
    let spectrum = AudioSpectrum(samples: samples, sampleRate: 48000)
    #expect(abs(spectrum.rms - 0.5 / sqrt(2)) < 0.01)
    let peak = spectrum.bands.indices.max { spectrum.bands[$0] < spectrum.bands[$1] }!
    let frequency = 40 * pow(18000.0 / 40, Double(peak) / 72)
    #expect(frequency > 850 && frequency < 1150)
    #expect(spectrum.bands.allSatisfy { $0.isFinite && (0...1).contains($0) })
}
