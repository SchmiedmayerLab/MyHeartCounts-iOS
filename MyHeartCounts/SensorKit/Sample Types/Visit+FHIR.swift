//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import SpeziHealthKitFHIR
import ModelsR4
import SensorKit
import SpeziSensorKit
import FHIRModelsExtensions


extension SRVisit.SafeRepresentation: HealthObservation {
    var id: UUID {
        var hasher = SensorKitSampleIDHasher()
        hasher.combine(self.timestamp)
        hasher.combine(self.locationId)
        hasher.combine(self.distanceFromHome)
        hasher.combine(self.arrivalDateInterval.start)
        hasher.combine(self.arrivalDateInterval.end)
        hasher.combine(self.departureDateInterval.start)
        hasher.combine(self.departureDateInterval.end)
        hasher.combine(self.locationCategory.rawValue)
        return hasher.finalize()
    }
    
    var sampleTypeIdentifier: String {
        Sensor.visits.id
    }
    
    func resource( // swiftlint:disable:this function_body_length
        withMapping mapping: HKSampleMapping,
        issuedDate: FHIRPrimitive<Instant>?,
        extensions: [any FHIRExtensionBuilderProtocol]
    ) throws -> ResourceProxy {
        let observation = Observation(
            code: CodeableConcept(),
            status: FHIRPrimitive(.final)
        )
        let sensorCoding = SensorKitCodingSystem(.visits)
        observation.id = self.id.uuidString.asFHIRStringPrimitive()
        observation.appendIdentifier(Identifier(id: observation.id))
        observation.appendCoding(Coding(code: sensorCoding))
        if let issuedDate {
            observation.issued = issuedDate
        } else {
            try observation.setIssued(on: .now)
        }
        // NOTE: `SRVisit` samples don't have a precise start and end date; instead their start and end times are represented as ranges,
        // with the actual start/end date being some time within that range.
        // We store the actual ranges in an extension, but set the effectivePeriod of the Observation as a whole to the max possible range,
        // ie arrivalRange.lowerBound..<departureRange.upperBound
        observation.effective = try .period(Period(
            end: FHIRPrimitive(DateTime(date: self.departureDateInterval.end)),
            start: FHIRPrimitive(DateTime(date: self.arrivalDateInterval.start))
        ))
        observation.value = .string(self.locationId.uuidString.asFHIRStringPrimitive())
        let sensorDomainUrl = FHIRExtensionUrls.sensorKitDomain.appending(component: "Visits")
        observation.appendExtensions([
            Extension(
                url: sensorDomainUrl.appending(component: "sensorKitTimestamp"),
                value: .dateTime(try FHIRPrimitive(DateTime(date: self.timestamp)))
            ),
            Extension(
                url: sensorDomainUrl.appending(component: "locationId"),
                value: .uuid(FHIRPrimitive(FHIRURI(self.locationId)))
            ),
            Extension(
                url: sensorDomainUrl.appending(component: "distanceFromHome"),
                value: .quantity(Quantity(unit: .meter, value: self.distanceFromHome))
            ),
            Extension(
                url: sensorDomainUrl.appending(component: "arrivalRangeStart"),
                value: .dateTime(try FHIRPrimitive(DateTime(date: self.arrivalDateInterval.start)))
            ),
            Extension(
                url: sensorDomainUrl.appending(component: "arrivalRangeEnd"),
                value: .dateTime(try FHIRPrimitive(DateTime(date: self.arrivalDateInterval.end)))
            ),
            Extension(
                url: sensorDomainUrl.appending(component: "departureRangeStart"),
                value: .dateTime(try FHIRPrimitive(DateTime(date: self.departureDateInterval.start)))
            ),
            Extension(
                url: sensorDomainUrl.appending(component: "departureRangeEnd"),
                value: .dateTime(try FHIRPrimitive(DateTime(date: self.departureDateInterval.end)))
            ),
            Extension(
                url: sensorDomainUrl.appending(component: "locationCategory"),
                value: .string(self.locationCategory.stringRepresentation.asFHIRStringPrimitive())
            )
        ], replaceAllExistingWithSameUrl: true)
        for builder in extensions {
            try builder.apply(typeErasedInput: self, to: observation)
        }
        observation.addMHCAppAsSource()
        return .observation(observation)
    }
}


extension SRVisit.LocationCategory {
    fileprivate var stringRepresentation: String {
        switch self {
        case .home:
            "home"
        case .work:
            "work"
        case .school:
            "school"
        case .gym:
            "gym"
        case .unknown:
            fallthrough
        @unknown default:
            "unknown"
        }
    }
}


extension FHIRURI {
    init(_ uuid: UUID) {
        guard let url = URL(string: "urn:uuid:\(uuid.uuidString.lowercased())") else {
            // NOTE: this is unreachable, bc UUIDs have a fixed format, and the string we place them into forms a valid, parseable URL.
            fatalError("Unable to create URL from UUID")
        }
        self.init(url)
    }
}
