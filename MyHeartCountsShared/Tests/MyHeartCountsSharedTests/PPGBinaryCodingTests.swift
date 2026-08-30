//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import MyHeartCountsShared
import Testing


@Suite
struct PPGBinaryCodingTests {
    @Test
    func encodeAndDecodeBinary() throws {
        let samples = [PPGSample.testSample1, .testSample2, .testSample3]
        let encoded = try BinaryEncoder.encode(samples)
        let decoded = try BinaryDecoder.decode([PPGSample].self, from: encoded)
        #expect(decoded == samples)
    }

    @Test
    func registeredBinaryRetainsLegacyFloatingPointOrder() throws {
        let sample = PPGSample(
            startDate: Date(timeIntervalSince1970: 1),
            nanosecondsSinceStart: 0,
            usage: [],
            opticalSamples: [],
            accelerometerSamples: [],
            temperature: nil
        )
        let encoded = try BinaryEncoder.encode([sample])
        #expect(encoded.getBytes(at: 1, length: 8) == [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x3f])
        #expect(try BinaryDecoder.decode([PPGSample].self, from: encoded) == [sample])
    }

    @Test
    func photodiodeIndexesHaveCanonicalOrder() throws {
        let sample = PPGSample.OpticalSample(
            emitter: 1,
            activePhotodiodeIndexes: [3, 1, 2],
            signalIdentifier: 0,
            nominalWavelength: 525,
            effectiveWavelength: 525,
            samplingFrequency: 128,
            nanosecondsSinceStart: 0,
            conditions: [],
            noiseTerms: nil,
            normalizedReflectance: nil
        )
        let encoded = try BinaryEncoder.encode(sample)
        #expect(encoded.getBytes(at: 0, length: 5) == [1, 3, 1, 2, 3])
        #expect(try BinaryDecoder.decode(PPGSample.OpticalSample.self, from: encoded) == sample)
    }
    
    @Test
    func encodeAndDecodeJSON() throws {
        let samples = [PPGSample.testSample1, .testSample2, .testSample3]
        let encoded = try JSONEncoder().encode(samples)
        let decoded = try JSONDecoder().decode([PPGSample].self, from: encoded)
        #expect(decoded == samples)
    }
}


extension PPGSample {
    static let testSample1 = PPGSample(
        startDate: Date(timeIntervalSinceReferenceDate: 788987687.6906688),
        nanosecondsSinceStart: 1346088365061625,
        usage: [PPGSample.Usage(rawValue: "ForegroundHeartRate")],
        opticalSamples: [
            PPGSample.OpticalSample(
                emitter: 10,
                activePhotodiodeIndexes: Set([2, 1]),
                signalIdentifier: 0,
                nominalWavelength: 525.0,
                effectiveWavelength: 525.0,
                samplingFrequency: 128.0,
                nanosecondsSinceStart: 1346088365060250,
                conditions: [],
                noiseTerms: PPGSample.OpticalSample.NoiseTerms(
                    whiteNoise: 2.7303497191020348e-14,
                    pinkNoise: 4.681273814768905e-13,
                    backgroundNoise: -9.205812148138648e-07,
                    backgroundNoiseOffset: 2.006131941340375e-13
                ),
                normalizedReflectance:
                    0.039113014936447144
            ),
            PPGSample.OpticalSample(
                emitter: 12,
                activePhotodiodeIndexes: Set([3, 0]),
                signalIdentifier: 0,
                nominalWavelength: 525.0,
                effectiveWavelength: 525.0,
                samplingFrequency: 128.0,
                nanosecondsSinceStart: 1346088365061167,
                conditions: [PPGSample.OpticalSample.Condition(rawValue: "SignalSaturation")],
                noiseTerms: PPGSample.OpticalSample.NoiseTerms(
                    whiteNoise: 3.443505382097825e-14,
                    pinkNoise: 7.85841227160522e-13,
                    backgroundNoise: 2.4058579128904967e-06,
                    backgroundNoiseOffset: 1.989058603154431e-13
                ),
                normalizedReflectance: 0.05067651346325874
            )
        ],
        accelerometerSamples: [
            PPGSample.AccelerometerSample(
                nanosecondsSinceStart: 1346088365061625,
                samplingFrequency: 128.0,
                x: 0.9739532470703125,
                y: 0.1337127685546875,
                z: -0.123687744140625
            )
        ],
        temperature: 32.453125
    )
    
    static let testSample2 = PPGSample(
        startDate: Date(timeIntervalSinceReferenceDate: 788987687.6906688),
        nanosecondsSinceStart: 1344525693675125,
        usage: [PPGSample.Usage(rawValue: "BackgroundSystem")],
        opticalSamples: [
            PPGSample.OpticalSample(
                emitter: 1,
                activePhotodiodeIndexes: Set([0]),
                signalIdentifier: 1,
                nominalWavelength: 850.0,
                effectiveWavelength: 852.4296875,
                samplingFrequency: 8.0,
                nanosecondsSinceStart: 1344525693674208,
                conditions: [],
                noiseTerms: PPGSample.OpticalSample.NoiseTerms(
                    whiteNoise: 2.4699371020675542e-11,
                    pinkNoise: 1.0345459731941897e-11,
                    backgroundNoise: -1.1798899322457146e-05,
                    backgroundNoiseOffset: 5.943066178071277e-11
                ),
                normalizedReflectance: 0.18387140333652496
            ),
            PPGSample.OpticalSample(
                emitter: 1,
                activePhotodiodeIndexes: Set([3]),
                signalIdentifier: 1,
                nominalWavelength: 850.0,
                effectiveWavelength: 852.4296875,
                samplingFrequency: 8.0,
                nanosecondsSinceStart: 1344525693674208,
                conditions: [],
                noiseTerms: PPGSample.OpticalSample.NoiseTerms(
                    whiteNoise: 2.4722019570377896e-11,
                    pinkNoise: 1.528420792706875e-11,
                    backgroundNoise: 8.43376801640261e-06,
                    backgroundNoiseOffset: 5.4747380240360854e-11
                ),
                normalizedReflectance: 0.2234913557767868
            )
        ],
        accelerometerSamples: [
            PPGSample.AccelerometerSample(
                nanosecondsSinceStart: 1344525584300125,
                samplingFrequency: 64.0,
                x: -0.488037109375,
                y: 0.72894287109375,
                z: 0.484283447265625
            ),
            PPGSample.AccelerometerSample(
                nanosecondsSinceStart: 1344525599925125,
                samplingFrequency: 64.0,
                x: -0.4883270263671875,
                y: 0.72552490234375,
                z: 0.480499267578125
            ),
            PPGSample.AccelerometerSample(
                nanosecondsSinceStart: 1344525615550125,
                samplingFrequency: 64.0,
                x: -0.488189697265625,
                y: 0.727264404296875,
                z: 0.48175048828125
            ),
            PPGSample.AccelerometerSample(
                nanosecondsSinceStart: 1344525631175125,
                samplingFrequency: 64.0,
                x: -0.488525390625,
                y: 0.7302703857421875,
                z: 0.4838104248046875
            ),
            PPGSample.AccelerometerSample(
                nanosecondsSinceStart: 1344525646800125,
                samplingFrequency: 64.0,
                x: -0.4892578125,
                y: 0.7341461181640625,
                z: 0.486358642578125
            ),
            PPGSample.AccelerometerSample(
                nanosecondsSinceStart: 1344525662425125,
                samplingFrequency: 64.0,
                x: -0.48651123046875,
                y: 0.730712890625,
                z: 0.4849090576171875
            ),
            PPGSample.AccelerometerSample(
                nanosecondsSinceStart: 1344525678050125,
                samplingFrequency: 64.0,
                x: -0.48016357421875,
                y: 0.72637939453125,
                z: 0.4789581298828125
            ),
            PPGSample.AccelerometerSample(
                nanosecondsSinceStart: 1344525693675125,
                samplingFrequency: 64.0,
                x: -0.483917236328125,
                y: 0.725250244140625,
                z: 0.477752685546875
            )
        ],
        temperature: 34.1015625
    )
    
    static let testSample3 = PPGSample(
//        startDate: 2026-01-01 19:14:47 +0000,
        startDate: Date(timeIntervalSinceReferenceDate: 788987687.6906688),
        nanosecondsSinceStart: 1346107022318958,
        usage: [
            PPGSample.Usage(rawValue: "ForegroundHeartRate"),
            PPGSample.Usage(rawValue: "BackgroundSystem")
        ],
        opticalSamples: [
            PPGSample.OpticalSample(
                emitter: 10,
                activePhotodiodeIndexes: Set([2, 1]),
                signalIdentifier: 0,
                nominalWavelength: 525.0,
                effectiveWavelength: 525.0,
                samplingFrequency: 128.0,
                nanosecondsSinceStart: 1346107022316208,
                conditions: [PPGSample.OpticalSample.Condition(rawValue: "SignalSaturation")],
                noiseTerms: PPGSample.OpticalSample.NoiseTerms(
                    whiteNoise: 3.311144964441258e-14,
                    pinkNoise: 7.17879477651201e-13,
                    backgroundNoise: -8.803055607131682e-06,
                    backgroundNoiseOffset: 2.0059102219961017e-13
                ),
                normalizedReflectance: 0.04843564331531525
            ),
            PPGSample.OpticalSample(
                emitter: 12,
                activePhotodiodeIndexes: Set([0, 3]),
                signalIdentifier: 0,
                nominalWavelength: 525.0,
                effectiveWavelength: 525.0,
                samplingFrequency: 128.0,
                nanosecondsSinceStart: 1346107022317125,
                conditions: [PPGSample.OpticalSample.Condition(rawValue: "SignalSaturation")],
                noiseTerms: PPGSample.OpticalSample.NoiseTerms(
                    whiteNoise: 3.3039550099717846e-14,
                    pinkNoise: 7.192040474453265e-13,
                    backgroundNoise: -7.045726761134574e-06,
                    backgroundNoiseOffset: 1.988823873384088e-13
                ),
                normalizedReflectance: 0.048480309545993805
            )
        ],
        accelerometerSamples: [
            PPGSample.AccelerometerSample(
                nanosecondsSinceStart: 1346106912943958,
                samplingFrequency: 64.0,
                x: 0.277587890625,
                y: 0.81646728515625,
                z: -0.2883758544921875
            ),
            PPGSample.AccelerometerSample(
                nanosecondsSinceStart: 1346106928568958,
                samplingFrequency: 64.0,
                x: 0.3888702392578125,
                y: 1.105133056640625,
                z: -0.3709716796875
            ),
            PPGSample.AccelerometerSample(
                nanosecondsSinceStart: 1346106944193958,
                samplingFrequency: 64.0,
                x: 0.305145263671875,
                y: 1.0943603515625,
                z: -0.296966552734375
            ),
            PPGSample.AccelerometerSample(
                nanosecondsSinceStart: 1346106959818958,
                samplingFrequency: 64.0,
                x: 0.1283111572265625,
                y: 0.8650970458984375,
                z: -0.155548095703125
            ),
            PPGSample.AccelerometerSample(
                nanosecondsSinceStart: 1346106975443958,
                samplingFrequency: 64.0,
                x: -0.02215576171875,
                y: 0.879364013671875,
                z: -0.1072540283203125
            ),
            PPGSample.AccelerometerSample(
                nanosecondsSinceStart: 1346106991068958,
                samplingFrequency: 64.0,
                x: -0.089019775390625,
                y: 1.0381622314453125,
                z: -0.2420654296875
            ),
            PPGSample.AccelerometerSample(
                nanosecondsSinceStart: 1346107006693958,
                samplingFrequency: 64.0,
                x: -0.06451416015625,
                y: 1.0237274169921875,
                z: -0.3580322265625
            ),
            PPGSample.AccelerometerSample(
                nanosecondsSinceStart: 1346107022318958,
                samplingFrequency: 64.0,
                x: 0.0022430419921875,
                y: 0.9289703369140625,
                z: -0.3621673583984375
            )
        ],
        temperature: 33.3125
    )
}
