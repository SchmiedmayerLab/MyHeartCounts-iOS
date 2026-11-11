//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import GroveFHIRContract
import GroveSensorKit
import GroveSensorKitFHIR


/// The devices a SensorKit batch states, in the form its retry state persists them.
///
/// SensorKit restates a batch's devices with each delivery, as they stand then, and a record's version digests the Devices
/// it names. A device renamed or updated while its batch is pending would otherwise make every redelivery a new version.
struct SensorBatchDevices: Codable, Equatable, Sendable {
    /// Every fact SensorKit states for a device.
    ///
    /// `name` is the name a person gave the device, which may name that person; keep it out of logs and upload metadata.
    struct Facts: Codable, Equatable, Sendable {
        let name: String?
        let manufacturer: String?
        let model: String?
        let productType: String?
        let systemName: String?
        let systemVersion: String?
        let hardwareVersion: String?
        let firmwareVersion: String?
        let localIdentifier: String?
    }

    /// The `SRDevice` that recorded the batch, which every output of its records names.
    let recording: Facts
    /// The peripherals that supplied the batch, which the Provenance of every one of its records names.
    let sources: [Facts]
    /// Whether every sample of the batch came from one of ``sources``, so a record may name its sole peripheral as its
    /// Observations' device.
    ///
    /// Retry state persisted before this flag existed decodes it as `false`, which keeps the batch's `SRDevice` as that device.
    let sourcesSuppliedEverySample: Bool

    var recordingDevice: RecordingDevice {
        recording.recordingDevice
    }

    var sourceDevices: [RecordingDevice] {
        sources.map(\.recordingDevice)
    }

    init(recording: Facts, sources: [Facts], sourcesSuppliedEverySample: Bool) {
        self.recording = recording
        self.sources = sources
        self.sourcesSuppliedEverySample = sourcesSuppliedEverySample
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recording = try container.decode(Facts.self, forKey: .recording)
        sources = try container.decode([Facts].self, forKey: .sources)
        sourcesSuppliedEverySample = try container.decodeIfPresent(Bool.self, forKey: .sourcesSuppliedEverySample) ?? false
    }
}


extension SensorBatchDevices {
    /// The devices `info` states.
    init(_ info: SensorKit.BatchInfo) {
        self.init(
            recording: Facts(RecordingDevice(info.device)),
            sources: info.sourceDevices.map { Facts(RecordingDevice($0)) },
            sourcesSuppliedEverySample: info.sourceDevicesSuppliedEverySample
        )
    }
}


extension SensorBatchDevices.Facts {
    fileprivate var recordingDevice: RecordingDevice {
        var device = RecordingDevice()
        device.name = name
        device.manufacturer = manufacturer
        device.model = model
        device.productType = productType
        device.systemName = systemName
        device.systemVersion = systemVersion
        device.hardwareVersion = hardwareVersion
        device.firmwareVersion = firmwareVersion
        device.localIdentifier = localIdentifier
        return device
    }

    /// The facts `device` states; the first delivery of a batch states them as they are persisted, as its redeliveries do.
    init(_ device: RecordingDevice) {
        self.init(
            name: device.name,
            manufacturer: device.manufacturer,
            model: device.model,
            productType: device.productType,
            systemName: device.systemName,
            systemVersion: device.systemVersion,
            hardwareVersion: device.hardwareVersion,
            firmwareVersion: device.firmwareVersion,
            localIdentifier: device.localIdentifier
        )
    }
}
