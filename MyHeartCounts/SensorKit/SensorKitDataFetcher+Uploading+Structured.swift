//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

@preconcurrency import FirebaseFirestore
import Foundation
import GroveFirestore
import GroveSensorKit
import GroveSensorKitFHIR
import ModelsR4
import SensorKit


/// A SensorKit sample Grove maps to a structured record rather than an opaque payload.
protocol GroveStructuredSensorSample: Sendable {
    /// Whether the record carries the exact native bytes alongside its structured fields.
    static var carriesNativeRecording: Bool { get }

    /// A producer-assigned identity derived from the sample's own fields.
    ///
    /// SensorKit assigns no durable identifier of its own.
    var groveRecordID: UUID { get }

    /// The sample's Grove record, given the producer-assigned identity and its exact native bytes.
    func groveRecord(recordID: UUID, nativeRecording: @autoclosure () throws -> SensorKitNativeRecording) throws -> SensorKitRecord

    /// The sample's exact native encoding, uploaded as the graph's recording document.
    func nativePayload() throws -> Data
}


/// Uploads each sample as a Grove structured graph instead of an opaque recording.
struct UploadStrategyStructured<Sample: SensorKitSampleProtocol>: MHCSensorSampleUploadStrategy
where Sample.SafeRepresentation: GroveStructuredSensorSample {
    func upload(
        _ samples: some RandomAccessCollection<Sample.SafeRepresentation> & Sendable,
        batchInfo: SensorKit.BatchInfo,
        for sensor: Sensor<Sample>,
        to standard: MyHeartCountsStandard,
        activity: SensorKitDataFetcher.InProgressActivity
    ) async throws {
        let subject = try await standard.firebaseConfiguration.subjectReference
        let collection = try await standard.firebaseConfiguration.userDocumentReference
            .collection("HealthObservations_\(sensor.id)")
        activity.updateMessage("Converting \(sensor.displayName)")
        for sample in samples {
            let recordID = sample.groveRecordID
            var sidecarPath: String?
            var payload = Data()
            if Sample.SafeRepresentation.carriesNativeRecording {
                payload = try sample.nativePayload()
                let filename = "\(recordID.uuidString).json"
                let url = URL.temporaryDirectory.appending(component: filename)
                try payload.write(to: url)
                await standard.uploadSensorKitFile(at: url, for: sensor)
                sidecarPath = "\(ManagedFileUpload.Category(sensor).firebasePath)/\(filename)"
            }
            let record = try sample.groveRecord(
                recordID: recordID,
                nativeRecording: try SensorKitNativeRecording(
                    title: "\(sensor.displayName) \(recordID.uuidString)",
                    contentType: RegisteredRecordingFormat.nativeRecording.registeredContentType,
                    format: .nativeRecording,
                    // SAFETY: only evaluated for records that declare they carry native bytes.
                    payload: .sidecar(path: sidecarPath ?? "", bytes: payload),
                    admission: .callerAuthorizedOpaquePayload
                )
            )
            let conversion = try SensorKitGroveRecording.convert(record, device: batchInfo.device, subject: subject)
            try await collection.document(recordID.uuidString).setData(from: conversion.bundle)
        }
    }
}


extension GroveStructuredSensorSample {
    static var carriesNativeRecording: Bool { false }

    func nativePayload() throws -> Data {
        Data()
    }
}
