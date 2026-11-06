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
import ModelsR4
@testable import MyHeartCounts
import Testing
import UIKit


/// Every field `ConversionFacts` keeps of an application and a host, which a swapped field would change silently.
@Suite
struct ConversionFactsTests {
    private static var application: ApplicationDevice {
        get throws {
            try ApplicationDevice(name: "My Heart Counts", bundleIdentifier: "edu.stanford.MyHeartCounts", version: "4.1", build: "100")
        }
    }

    /// A host stating every fact, each with a value of its own.
    private static var host: HostDevice {
        get throws {
            try HostDevice(
                operatingSystemName: "iOS",
                operatingSystemVersion: "26.1",
                operatingSystemBuild: "23B85",
                productType: "iPhone18,1",
                model: "iPhone",
                name: "Host iPhone",
                manufacturer: "Apple"
            )
        }
    }

    private static var facts: MyHeartCounts::ConversionFacts {
        get throws {
            MyHeartCounts::ConversionFacts(application: try application, host: try host, study: .init(id: "study", revision: 1))
        }
    }

    private let uploads = RecordedSensorKitUploads()

    @Test
    func factsKeepEveryHostField() throws {
        let facts = try Self.facts
        #expect(facts.hostOperatingSystemName == "iOS")
        #expect(facts.hostOperatingSystemVersion == "26.1")
        #expect(facts.hostOperatingSystemBuild == "23B85")
        #expect(facts.hostProductType == "iPhone18,1")
        #expect(facts.hostModel == "iPhone")
        #expect(facts.hostName == "Host iPhone")
        #expect(facts.hostManufacturer == "Apple")
    }

    @Test
    func factsRestateTheirApplicationAndHost() throws {
        let facts = try Self.facts
        #expect(try facts.host == Self.host)
        #expect(try facts.application == Self.application)
    }

    /// The facts of the moment hold what `UIDevice` states of the host, and what Grove reads of it.
    @MainActor
    @Test
    func currentFactsCaptureTheHost() async throws {
        let facts = try await MyHeartCounts::ConversionFacts.current()
        let host = HostDevice.current()
        #expect(facts.hostOperatingSystemName == UIDevice.current.systemName)
        #expect(facts.hostModel == UIDevice.current.model)
        #expect(facts.hostName == UIDevice.current.name)
        #expect(facts.hostManufacturer == "Apple")
        #expect(facts.hostOperatingSystemVersion == host.operatingSystemVersion)
        #expect(facts.hostOperatingSystemBuild == host.operatingSystemBuild)
        #expect(facts.hostProductType == host.productType)
    }

    /// A batch's facts come back from its persisted state with every field, and a redelivery states them, each in its own
    /// element of the host Device.
    @Test
    func aRedeliveryStatesEveryHostFactOfThePersistedBatch() async throws {
        let harness = SensorKitPublicationHarness(sensor: Sensor.deviceUsage, sequence: 52)
        let report = DeviceUsageFHIRExchangeTests.report()
        let first = try harness.publication(uploads: RecordedSensorKitUploads(), facts: Self.facts)
        #expect(try await first.batchFacts().conversionFacts == Self.facts)

        let redelivery = try harness.publication(uploads: uploads, facts: .testing())
        #expect(try await redelivery.batchFacts().conversionFacts == Self.facts)
        try await DeviceUsageFHIRExchangeTests.upload([report], publication: redelivery)

        let bundle = try JSONDecoder().decode(ModelsR4.Bundle.self, from: try #require(try uploads.bundles.first))
        let hosts = (bundle.entry ?? []).compactMap { $0.resource?.get(if: ModelsR4.Device.self) }.filter {
            $0.meta?.profile?.contains(Profile.groveHostDevice) == true
        }
        #expect(hosts.count == 1)
        let host = try #require(hosts.first)
        #expect(host.statedNames == [.userFriendlyName: "Host iPhone", .modelName: "iPhone"])
        #expect(host.manufacturer?.value?.string == "Apple")
        #expect(host.modelNumber?.value?.string == "iPhone18,1")
        #expect(host.statedVersions(code: "os-name") == ["iOS"])
        #expect(host.statedVersions(code: "os-version") == ["26.1"])
        #expect(host.statedVersions(code: "os-build") == ["23B85"])
    }
}
