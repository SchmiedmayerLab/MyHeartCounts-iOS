//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

@preconcurrency import FirebaseFirestore
import Foundation
import GroveFirestore
import GroveSensorKit
import GroveSensorKitFHIR


extension MHCSensorSampleUploadStrategy {
    func upload( // swiftlint:disable:this function_parameter_count
        data: consuming Data,
        for sensor: Sensor<Sample>,
        effectiveTimeRange: Swift.Range<Date>,
        publication: SensorKitBatchPublication,
        to standard: MyHeartCountsStandard,
        activity: SensorKitDataFetcher.InProgressActivity,
        recordOrdinal: Int = 0,
        retryEvidence: Data? = nil,
        makeStructuredRecord: (
            (SensorKitSourceRecordID, SensorKitNativeRecording) throws -> SensorKitRecord?
        )? = nil
    ) async throws {
        let reservation = try publication.reserve(
            recordOrdinal: recordOrdinal,
            evidence: retryEvidence ?? data
        )
        let filename = "\(reservation.sourceRecordID.value).\(try publication.stream.fileExtension)"
        let title = "\(sensor.displayName) "
            + "\(effectiveTimeRange.lowerBound.ISO8601Format())_\(effectiveTimeRange.upperBound.ISO8601Format())"
        let sidecarPath = "\(ManagedFileUpload.Category(sensor).firebasePath)/\(filename)"
        activity.updateMessage("Creating Recording Document")
        let conversion: SensorKitConversion
        if let makeStructuredRecord {
            let recording = try SensorKitNativeRecording(
                title: title,
                format: try publication.stream.recordingFormat,
                payload: .sidecar(path: sidecarPath, bytes: data),
                admission: .callerAuthorizedOpaquePayload
            )
            if let record = try makeStructuredRecord(reservation.sourceRecordID, recording) {
                conversion = try SensorKitGroveRecording.convert(record, reservation: reservation)
            } else {
                conversion = try SensorKitGroveRecording.raw(
                    payload: data,
                    reservation: reservation,
                    stream: publication.stream,
                    sidecarPath: sidecarPath,
                    title: title,
                    effectiveTimeRange: effectiveTimeRange
                )
            }
        } else {
            conversion = try SensorKitGroveRecording.raw(
                payload: data,
                reservation: reservation,
                stream: publication.stream,
                sidecarPath: sidecarPath,
                title: title,
                effectiveTimeRange: effectiveTimeRange
            )
        }

        // Conversion validates the complete graph before its referenced exact bytes become durably staged.
        // The registered format describes these bytes, so the sidecar remains uncompressed.
        let url = URL.temporaryDirectory.appending(component: filename)
        try data.write(to: url, options: .atomic)
        activity.updateMessage("Submitting for upload")
        // Note: this waits until the upload is durably scheduled (i.e., the file is in the upload module's custody),
        // not until the file has actually been uploaded. If the scheduling fails, we abort (and in particular don't
        // write the reference doc below, which would otherwise point to a file that will never exist).
        try await standard.uploadSensorKitFile(at: url, for: sensor)

        // Do not introduce a cancellation point here: the sidecar is now durably staged, so its one
        // complete Bundle must be persisted before the anchored batch may be acknowledged.
        try await standard.firebaseConfiguration.userDocumentReference
            .collection("HealthObservations_\(sensor.id)")
            .document(reservation.sourceRecordID.value)
            .setData(from: conversion.bundle)
    }
}
