//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// periphery:ignore:all - API

import Foundation
import NIOCore


extension PPGSample: BinaryCodable {
    public init(fromBinary decoder: BinaryDecoder) throws {
        let startDate = try decoder.decode(Date.self)
        let nanosecondsSinceStart = try decoder.decode(Int64.self)
        let temperature = try decoder.decode(Double?.self)
        let usage = try decoder.decode([Usage].self)
        let opticalSamples = try decoder.decode([OpticalSample].self)
        let accelerometerSamples = try decoder.decode([AccelerometerSample].self)
        self.init(
            startDate: startDate,
            nanosecondsSinceStart: nanosecondsSinceStart,
            usage: usage,
            opticalSamples: opticalSamples,
            accelerometerSamples: accelerometerSamples,
            temperature: temperature
        )
    }
    
    public func binaryEncode(to encoder: BinaryEncoder) throws {
        try encoder.encode(self.startDate.timeIntervalSince1970)
        try encoder.encode(self.nanosecondsSinceStart)
        try encoder.encode(self.temperature)
        try encoder.encode(self.usage)
        try encoder.encode(self.opticalSamples)
        try encoder.encode(self.accelerometerSamples)
    }
}


extension PPGSample.Usage: BinaryCodable {
    public init(fromBinary decoder: BinaryDecoder) throws {
        self.init(rawValue: try decoder.decode(String.self))
    }
    
    public func binaryEncode(to encoder: BinaryEncoder) throws {
        try encoder.encode(rawValue)
    }
}


extension PPGSample.OpticalSample: BinaryCodable {
    public init(fromBinary decoder: BinaryDecoder) throws {
        self.init(
            emitter: try decoder.decode(Int.self),
            activePhotodiodeIndexes: try decoder.decode(Set<Int>.self),
            signalIdentifier: try decoder.decode(Int.self),
            nominalWavelength: try decoder.decode(Double.self),
            effectiveWavelength: try decoder.decode(Double.self),
            samplingFrequency: try decoder.decode(Double.self),
            nanosecondsSinceStart: try decoder.decode(Int64.self),
            conditions: try decoder.decode([Condition].self),
            noiseTerms: try decoder.decode(NoiseTerms?.self),
            normalizedReflectance: try decoder.decode(Double?.self)
        )
    }
    
    public func binaryEncode(to encoder: BinaryEncoder) throws {
        try encoder.encode(self.emitter)
        try encoder.encodeLengthPrefixed(self.activePhotodiodeIndexes.sorted())
        try encoder.encode(self.signalIdentifier)
        try encoder.encode(self.nominalWavelength)
        try encoder.encode(self.effectiveWavelength)
        try encoder.encode(self.samplingFrequency)
        try encoder.encode(self.nanosecondsSinceStart)
        try encoder.encode(self.conditions)
        try encoder.encode(self.noiseTerms)
        try encoder.encode(self.normalizedReflectance)
    }
}


extension PPGSample.OpticalSample.NoiseTerms: BinaryCodable {
    public init(fromBinary decoder: BinaryDecoder) throws {
        self.init(
            whiteNoise: try decoder.decode(Double.self),
            pinkNoise: try decoder.decode(Double.self),
            backgroundNoise: try decoder.decode(Double.self),
            backgroundNoiseOffset: try decoder.decode(Double.self)
        )
    }
    
    public func binaryEncode(to encoder: BinaryEncoder) throws {
        try encoder.encode(self.whiteNoise)
        try encoder.encode(self.pinkNoise)
        try encoder.encode(self.backgroundNoise)
        try encoder.encode(self.backgroundNoiseOffset)
    }
}


extension PPGSample.OpticalSample.Condition: BinaryCodable {
    public init(fromBinary decoder: BinaryDecoder) throws {
        self.init(rawValue: try decoder.decode(String.self))
    }
    
    public func binaryEncode(to encoder: BinaryEncoder) throws {
        try encoder.encode(self.rawValue)
    }
}


extension PPGSample.AccelerometerSample: BinaryCodable {
    public init(fromBinary decoder: BinaryDecoder) throws {
        self.init(
            nanosecondsSinceStart: try decoder.decode(Int64.self),
            samplingFrequency: try decoder.decode(Double.self),
            x: try decoder.decode(Double.self),
            y: try decoder.decode(Double.self),
            z: try decoder.decode(Double.self)
        )
    }
    
    public func binaryEncode(to encoder: BinaryEncoder) throws {
        try encoder.encode(self.nanosecondsSinceStart)
        try encoder.encode(self.samplingFrequency)
        try encoder.encode(self.x)
        try encoder.encode(self.y)
        try encoder.encode(self.z)
    }
}
