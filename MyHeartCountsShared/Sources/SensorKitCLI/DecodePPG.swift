//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import ArgumentParser
import Foundation
import GroveFoundation
import GroveSensorKitFHIR
import MyHeartCountsShared


struct DecodePPG: ParsableCommand {
    private struct CommandError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        init(_ message: String) {
            self.message = message
        }
    }
    
    /// Which encoding a file holds; the bytes carry no version, so the file's extension decides.
    private enum Encoding {
        /// `.mhcPPG`: written by My Heart Counts before the app adopted Grove's registered PPG format.
        case legacy
        /// `.mhcPPG2`: Grove's registered `photoplethysmogram-samples` format.
        case registered
    }
    
    static let configuration = CommandConfiguration(
        commandName: "decode-ppg",
        abstract: "Decode binary PPG data files created by My Heart Counts",
        discussion: "Reads .mhcPPG files (the original encoding) and .mhcPPG2 files (Grove's registered PPG format);"
            + " the extension selects the decoder."
    )
    
    /// Suffixes some earlier `.mhcPPG` files carry although their bytes are not compressed; the extension before one
    /// names the encoding.
    private static let compressionSuffixes: Set<String> = ["zstd", "zlib"]
    
    @Argument(help: "The input file (.mhcPPG or .mhcPPG2)")
    var input: String
    
    @Argument(help: "The output file")
    var output: String? = nil
    
    /// The encoding the file's extension names.
    private static func encoding(of url: URL) throws -> Encoding {
        var url = url
        if compressionSuffixes.contains(url.pathExtension) {
            url.deletePathExtension()
        }
        switch url.pathExtension {
        case "mhcPPG": return .legacy
        case "mhcPPG2": return .registered
        default: throw CommandError("\(url.lastPathComponent) is neither a .mhcPPG nor a .mhcPPG2 file.")
        }
    }
    
    /// The instant in ISO 8601 UTC, with its fractional seconds exactly as the shortest decimal of its binary64 seconds
    /// since 1970 states them: `.iso8601` drops the fraction, and every sample's offset counts from this instant.
    private static func preciseISO8601(_ date: Date) -> String {
        let seconds = date.timeIntervalSince1970
        let shortest = String(seconds)
        guard seconds >= 0, !shortest.contains("e"), let point = shortest.firstIndex(of: "."),
              let whole = Double(shortest[..<point]) else {
            return date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }
        let fraction = shortest[shortest.index(after: point)...]
        let base = Date(timeIntervalSince1970: whole).ISO8601Format()
        return fraction == "0" ? base : "\(base.dropLast()).\(fraction)Z"
    }
    
    func run() throws {
        let inputUrl = URL(filePath: input, relativeTo: .currentDirectory())
        let data = try Data(contentsOf: inputUrl)
        let recording: SensorKitPPGRecording
        do {
            recording = switch try Self.encoding(of: inputUrl) {
            case .legacy: try SensorKitPPGRecording(legacyMyHeartCountsData: data)
            case .registered: try SensorKitPPGRecording(data: data)
            }
        } catch let error where Self.compressionSuffixes.contains(inputUrl.pathExtension) {
            throw CommandError("Unable to decode \(inputUrl.lastPathComponent) (\(error)); if it is compressed, decompress it first.")
        }
        let samples = recording.records.map(PPGSample.init)
        let jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.preciseISO8601(date))
        }
        jsonEncoder.outputFormatting = [.prettyPrinted]
        let samplesJSON = try jsonEncoder.encode(consume samples)
        if let outputUrl = output.map({ URL(filePath: $0, relativeTo: .currentDirectory()) }) {
            try samplesJSON.write(to: outputUrl)
        } else {
            print(String(decoding: consume samplesJSON, as: UTF8.self))
        }
    }
}


extension PPGSample {
    fileprivate init(_ record: SensorKitPPGRecording.Record) {
        self.init(
            startDate: record.startDate,
            nanosecondsSinceStart: record.nanosecondsSinceStart,
            usage: record.usage.map(Usage.init(rawValue:)),
            opticalSamples: record.opticalSamples.map(OpticalSample.init),
            accelerometerSamples: record.accelerometerSamples.map {
                AccelerometerSample(
                    nanosecondsSinceStart: $0.nanosecondsSinceStart,
                    samplingFrequency: $0.samplingFrequency,
                    x: $0.x,
                    y: $0.y,
                    z: $0.z
                )
            },
            temperature: record.temperature
        )
    }
}


extension PPGSample.OpticalSample {
    fileprivate init(_ sample: SensorKitPPGRecording.OpticalSample) {
        self.init(
            emitter: Int(sample.emitter),
            activePhotodiodeIndexes: Set(sample.activePhotodiodeIndexes.map { Int(truncatingIfNeeded: $0) }),
            signalIdentifier: Int(sample.signalIdentifier),
            nominalWavelength: sample.nominalWavelength,
            effectiveWavelength: sample.effectiveWavelength,
            samplingFrequency: sample.samplingFrequency,
            nanosecondsSinceStart: sample.nanosecondsSinceStart,
            conditions: sample.conditions.map(Condition.init(rawValue:)),
            noiseTerms: sample.noiseTerms.map {
                NoiseTerms(
                    whiteNoise: $0.whiteNoise,
                    pinkNoise: $0.pinkNoise,
                    backgroundNoise: $0.backgroundNoise,
                    backgroundNoiseOffset: $0.backgroundNoiseOffset
                )
            },
            normalizedReflectance: sample.normalizedReflectance
        )
    }
}
