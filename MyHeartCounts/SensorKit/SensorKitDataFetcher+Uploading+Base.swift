//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import CryptoKit
import FHIRModelsExtensions
@preconcurrency import FirebaseFirestore
import Foundation
import HealthKitOnFHIR
import ModelsR4
import SpeziFirestore
import SpeziFoundation
import SpeziSensorKit


extension MHCSensorSampleUploadStrategy {
    func upload( // swiftlint:disable:this function_parameter_count
        data: consuming Data,
        fileExtension: String,
        shouldCompress: Bool = true,
        for sensor: Sensor<Sample>,
        deviceInfo: SensorKit.DeviceInfo,
        to standard: MyHeartCountsStandard,
        observationDocName: String,
        activity: SensorKitDataFetcher.InProgressActivity,
        postprocessObservation: (Observation) throws -> Void
    ) async throws {
        activity.updateMessage("Compressing Data")
        let data = shouldCompress ? try (consume data).compressed(using: Zstd.self) : consume data
        let sha1 = Insecure.SHA1.hash(data: data)
        let size = data.count
        let url = URL.temporaryDirectory
            .appending(component: UUID().uuidString)
            .appendingPathExtension("\(fileExtension)\(shouldCompress ? ".zstd" : "")")
        try (consume data).write(to: url)
        
        activity.updateMessage("Submitting for upload")
        // Note: this call does not wait for the upload to get completed;
        // it just looks like it bc the standard is an actor...
        await standard.uploadSensorKitFile(at: url, for: sensor)
        
        let referenceDocName = observationDocName + "_Ref"
        
        let attachment = Attachment(
            contentType: "application/zstd",
            creation: try FHIRPrimitive(DateTime(date: .now)),
            hash: FHIRPrimitive(Base64Binary(Data(sha1).base64EncodedString())),
            // for some reason, R4 uses a "32-bit unsigned integer"
            // (which is what they say when they actually mean a 31-bit unsigned integer; don't ask why)
            // to store the size of the attachment.
            // this means, in effect, that we can provide size info for files up to 2GB.
            // for anything above that, we set the size to nil.
            size: Int32(exactly: size).map { FHIRPrimitive(FHIRUnsignedInteger($0)) },
            // NOTE: we use a path relative to this user's storage directory here!
            url: ManagedFileUpload.Category(sensor).firebasePath.asFHIRURIPrimitive()!.appending(component: url.lastPathComponent)
            // swiftlint:disable:previous force_unwrapping
        )
        let reference = DocumentReference(
            content: [.init(attachment: attachment)],
            status: FHIRPrimitive(.current)
        )
        
        let observation = Observation(
            code: CodeableConcept(),
            status: FHIRPrimitive(.final)
        )
        observation.id = observationDocName.asFHIRStringPrimitive()
        observation.appendCoding(Coding(code: SensorKitCodingSystem(sensor)))
        try observation.setIssued(on: .now)
        observation.appendElement(
            // Note: the value here has to match the firestore document used to upload the reference!
            Reference(reference: "HealthObservations_\(sensor.id)/\(referenceDocName)".asFHIRStringPrimitive()),
            to: \.derivedFrom
        )
        
        observation.addMHCAppAsSource()
        try observation.apply(.sensorKitSourceDevice, input: deviceInfo)
        for builder in MyHeartCountsStandard.defaultHealthObservationFHIRExtensions {
            try builder.apply(typeErasedInput: self, to: observation)
        }
        try postprocessObservation(observation)
        
        let sensorCollection = try await standard.firebaseConfiguration.userDocumentReference
            .collection("HealthObservations_\(sensor.id)")
        try await sensorCollection.document(referenceDocName).setData(from: reference)
        try await sensorCollection.document(observationDocName).setData(from: observation)
    }
}
