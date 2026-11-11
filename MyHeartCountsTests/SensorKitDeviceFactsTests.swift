//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveSensorKit
import GroveSensorKitFHIR
import ModelsR4
@testable import MyHeartCounts
import MyHeartCountsShared
import Testing


/// Where a SensorKit batch's device facts travel: every one of them in its Bundle, and only the product type beside it.
@Suite
struct SensorKitDeviceFactsTests {
    private let harness = SensorKitPublicationHarness(sensor: Sensor.deviceUsage, sequence: 51)
    private let uploads = RecordedSensorKitUploads()

    /// The one staged Bundle.
    private var bundle: ModelsR4.Bundle {
        get throws {
            try JSONDecoder().decode(ModelsR4.Bundle.self, from: try #require(try uploads.bundles.first))
        }
    }

    /// The staged Bundle's recording Devices, each with its fullUrl.
    private var recordingDevices: [(url: String, device: ModelsR4.Device)] {
        get throws {
            (try bundle.entry ?? []).compactMap { entry in
                guard let device = entry.resource?.get(if: ModelsR4.Device.self),
                      device.meta?.profile?.contains(Profile.groveRecordingDevice) == true,
                      let url = entry.fullUrl?.value?.url.absoluteString else {
                    return nil
                }
                return (url, device)
            }
        }
    }

    private func publish(through publication: SensorKitBatchPublication) async throws {
        try await DeviceUsageFHIRExchangeTests.upload([DeviceUsageFHIRExchangeTests.report()], publication: publication)
    }

    /// The recording Device states every fact of the `SRDevice`, each in its own element, and every output names it.
    @Test
    func everyOutputNamesTheRecordingDevice() async throws {
        try await publish(through: harness.publication(uploads: uploads))

        let devices = try recordingDevices
        try #require(devices.count == 1)
        let (url, device) = devices[0]
        #expect(device.statedNames == [.userFriendlyName: "Pinned iPhone", .modelName: "iPhone"])
        #expect(device.modelNumber?.value?.string == "iPhone18,1")
        #expect(device.statedVersions(code: "os-name") == ["iOS"])
        #expect(device.statedVersions(code: "os-version") == ["26.0"])

        let resources = try bundle.entry?.compactMap(\.resource) ?? []
        let documents = resources.compactMap { $0.get(if: DocumentReference.self) }
        #expect(documents.count == 1)
        for document in documents {
            #expect(document.author?.contains { $0.reference?.value?.string == url } == true)
        }
        for observation in resources.compactMap({ $0.get(if: Observation.self) }) {
            #expect(observation.device?.reference?.value?.string == url)
        }
    }

    /// A peripheral is a recording Device of its own, stating every fact of the `SRSourceDevice`, which the Provenance's
    /// source entity names as its performer, beside the `SRDevice` as its composer. Unless the peripheral supplied every
    /// sample, every output keeps naming the `SRDevice`.
    @Test
    func theProvenanceNamesEveryPeripheralAsAPerformer() async throws {
        try await publish(through: harness.publication(uploads: uploads, sourceDevices: [.pinnedPeripheral()]))

        let devices = try recordingDevices
        #expect(devices.count == 2)
        let recording = try #require(devices.first { $0.device.modelNumber?.value?.string == "iPhone18,1" })
        let peripheral = try #require(devices.first { $0.device.modelNumber?.value?.string == "Ear One" })
        #expect(peripheral.url != recording.url)
        #expect(peripheral.device.manufacturer?.value?.string == "Example Audio")
        #expect(peripheral.device.statedVersions(code: "531974") == ["2"])
        #expect(peripheral.device.statedVersions(code: "531976") == ["5.1"])
        let identifiers = peripheral.device.identifier ?? []
        #expect(identifiers.contains { $0.value?.value?.string == "peripheral-7" })

        let resources = try bundle.entry?.compactMap(\.resource) ?? []
        let provenances = resources.compactMap { $0.get(if: Provenance.self) }
        #expect(provenances.count == 1)
        let agents = try #require(provenances.first?.entity?.first?.agent)
        #expect(agents.map(\.who.reference?.value?.string) == [peripheral.url, recording.url])
        #expect(agents.map { $0.type?.coding?.first?.code?.value?.string } == ["performer", "composer"])
        let documents = resources.compactMap { $0.get(if: DocumentReference.self) }
        #expect(!documents.contains { $0.author?.contains { $0.reference?.value?.string == peripheral.url } == true })
        let observations = resources.compactMap { $0.get(if: Observation.self) }
        #expect(!observations.isEmpty)
        #expect(observations.allSatisfy { $0.device?.reference?.value?.string == recording.url })
    }

    /// A sole peripheral that supplied every sample of the batch is the device its Observations name; the `SRDevice` stays
    /// the composer and the Recording Document's author.
    @Test
    func aSolePeripheralThatSuppliedEverySampleIsTheObservationsDevice() async throws {
        try await publish(through: harness.publication(
            uploads: uploads,
            sourceDevices: [.pinnedPeripheral()],
            sourceDevicesSuppliedEverySample: true
        ))

        let devices = try recordingDevices
        #expect(devices.count == 2)
        let recording = try #require(devices.first { $0.device.modelNumber?.value?.string == "iPhone18,1" })
        let peripheral = try #require(devices.first { $0.device.modelNumber?.value?.string == "Ear One" })
        let resources = try bundle.entry?.compactMap(\.resource) ?? []
        let observations = resources.compactMap { $0.get(if: Observation.self) }
        #expect(!observations.isEmpty)
        #expect(observations.allSatisfy { $0.device?.reference?.value?.string == peripheral.url })
        let agents = try #require(resources.compactMap { $0.get(if: Provenance.self) }.first?.entity?.first?.agent)
        #expect(agents.map(\.who.reference?.value?.string) == [peripheral.url, recording.url])
        for document in resources.compactMap({ $0.get(if: DocumentReference.self) }) {
            #expect(document.author?.contains { $0.reference?.value?.string == recording.url } == true)
        }
    }

    /// `SRDevice.name` is the name a person gave the device: it enters the recording Device only. The batch's info, the
    /// file's metadata and every name state the device's product type at most.
    @Test
    func onlyTheProductTypeTravelsBesideTheBundle() async throws {
        try await publish(through: harness.publication(uploads: uploads))

        let file = try #require(uploads.all.first)
        let batchInfo = try #require(try uploads.entries.first { $0.path == "batchinfo.json" }).contents
        #expect(try uploads.archives.first?.info.device == "iPhone18,1")
        #expect(file.metadata == [UploadBatchArchive.batchInfoMetadataKey: String(decoding: batchInfo, as: UTF8.self)])
        let beside = try [file.path, String(decoding: batchInfo, as: UTF8.self)] + uploads.entries.map(\.path)
        #expect(!beside.contains { $0.contains("Pinned iPhone") })
        #expect(String(decoding: try #require(try uploads.bundles.first), as: UTF8.self).contains("Pinned iPhone"))
    }

    /// The form the devices persist in loses no fact: what a redelivery reads back, as what the first delivery states, equals
    /// what Grove maps from SensorKit's.
    @Test
    func persistedDevicesKeepEveryFact() async throws {
        let publication = try harness.publication(
            uploads: uploads,
            sourceDevices: [.pinnedPeripheral()],
            sourceDevicesSuppliedEverySample: true
        )
        let first = try await publication.batchFacts().devices
        let redelivered = try await publication.batchFacts().devices

        for devices in [first, redelivered] {
            #expect(devices.recordingDevice == RecordingDevice(publication.info.device))
            #expect(devices.sourceDevices == [RecordingDevice(SensorKit.SourceDeviceInfo.pinnedPeripheral())])
            #expect(devices.sourcesSuppliedEverySample)
        }
    }

    /// Retry state persisted before the batch stated whether its peripherals supplied every sample reads back as not
    /// stating it, so a redelivery keeps naming the `SRDevice` as its Observations' device.
    @Test
    func devicesPersistedWithoutTheSampleFlagReadBackWithoutIt() throws {
        let devices = SensorBatchDevices.testing(sources: [.pinnedPeripheral()], sourcesSuppliedEverySample: true)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(devices)) as? [String: Any])
        #expect(object.removeValue(forKey: "sourcesSuppliedEverySample") as? Bool == true)
        let legacy = try JSONDecoder().decode(SensorBatchDevices.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.recording == devices.recording)
        #expect(legacy.sources == devices.sources)
        #expect(!legacy.sourcesSuppliedEverySample)
    }
}


extension ModelsR4.Device {
    /// The names the Device states, by type.
    var statedNames: [DeviceNameType?: String?] {
        Dictionary(uniqueKeysWithValues: (deviceName ?? []).map { ($0.type.value, $0.name.value?.string) })
    }

    /// The values the Device states under the version type `code`.
    func statedVersions(code: String) -> [String?] {
        (version ?? []).filter { $0.type?.coding?.first?.code?.value?.string == code }.map { $0.value.value?.string }
    }
}
