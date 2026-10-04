//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveHealthKitFHIR
import HealthKit
import ModelsR4
@testable import MyHeartCounts
import ObjectiveC
import Testing


/// MHC's HealthKit export options state a sample's writer only for the sources MHC classified: itself.
@Suite
struct HealthKitExportOptionsTests {
    /// A step sample as HealthKit hands it back once `bundleIdentifier` saved it.
    ///
    /// HealthKit vends an `HKSource` only for the running process, and an unsaved sample names no source, so
    /// the source is written into the sample's storage the way Grove's own stored-sample fixtures do.
    private static func sample(writtenBy bundleIdentifier: String, name: String) throws -> HKQuantitySample {
        let sample = LedgerHarness.steps(0)
        let source = try #require(class_createInstance(HKSource.self, 0) as? HKSource)
        source.setValue(name, forKey: "name")
        source.setValue(bundleIdentifier, forKey: "bundleIdentifier")
        let revision = HKSourceRevision(
            source: source,
            version: "1",
            productType: "iPhone18,1",
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        )
        sample.setValue(revision, forKey: "sourceRevision")
        try #require(sample.sourceRevision.source.bundleIdentifier == bundleIdentifier, "HealthKit ignored the written source")
        return sample
    }

    /// The Device the graph's Provenance names as its author, if any.
    private static func author(in graph: ExchangeGraph) throws -> Device? {
        let bundle = graph.bundle
        let provenance = try #require(bundle.entry?.compactMap { $0.resource?.get(if: Provenance.self) }.first)
        let author = provenance.entity?.first?.agent?.first { agent in
            agent.type?.coding?.contains { $0.code?.value?.string == "author" } == true
        }
        guard let reference = author?.who.reference?.value?.string else {
            return nil
        }
        return try #require(bundle.entry?.first { $0.fullUrl?.value?.url.absoluteString == reference }?.resource?.get(if: Device.self))
    }

    private static func graph(of sample: HKSample) throws -> ExchangeGraph {
        var graph: ExchangeGraph?
        _ = try LedgerHarness(ledger: .forTesting()).exporter().export([sample]) { export in
            graph = export.graph
        }
        return try #require(graph)
    }

    @Test
    func sampleMHCWroteStatesMHCAsItsAuthor() throws {
        let bundleIdentifier = try #require(Bundle.main.bundleIdentifier)
        let sample = try Self.sample(writtenBy: bundleIdentifier, name: "My Heart Counts")
        let author = try #require(try Self.author(in: Self.graph(of: sample)))

        #expect(author.deviceName?.first?.name.value?.string == "My Heart Counts")
        #expect(author.version?.contains { $0.value.value?.string == "1" } == true)
    }

    @Test
    func sampleAnotherSourceWroteStatesNoAuthor() throws {
        let sample = try Self.sample(writtenBy: "org.example.other-app", name: "Other App")

        #expect(try Self.author(in: Self.graph(of: sample)) == nil)
    }
}
