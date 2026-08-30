//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import FHIRModelsExtensions
import Foundation
import GroveHealthKit
import HealthKit
import ModelsR4
@testable import MyHeartCounts
import Testing


@Suite
struct QuestionnaireQuantityContractTests {
    @Test
    func quantityRejectsDisplayUnitWithoutAuthoritativeCode() throws {
        let responseJSON = Data(#"""
        {
          "resourceType":"QuestionnaireResponse",
          "status":"completed",
          "authored":"2026-08-29T12:00:00-07:00",
          "item":[{
            "linkId":"weight",
            "answer":[{"valueQuantity":{"value":70,"unit":"kg"}}]
          }]
        }
        """#.utf8)
        let response = try JSONDecoder().decode(QuestionnaireResponse.self, from: responseJSON)

        #expect(throws: QuestionnaireDataExtractionError.incompleteQuantity(linkID: "weight")) {
            _ = try QuestionnaireDataExtractor(response: response).quantitySample(
                SampleType<HKQuantitySample>.bodyMass,
                linkID: "weight"
            )
        }
    }

    @Test
    func quantityRejectsUnboundUCUMCode() throws {
        let responseJSON = Data(#"""
        {
          "resourceType":"QuestionnaireResponse",
          "status":"completed",
          "authored":"2026-08-29T12:00:00-07:00",
          "item":[{
            "linkId":"weight",
            "answer":[{"valueQuantity":{"value":70,"system":"http://unitsofmeasure.org","code":"rad"}}]
          }]
        }
        """#.utf8)
        let response = try JSONDecoder().decode(QuestionnaireResponse.self, from: responseJSON)

        #expect(throws: QuestionnaireDataExtractionError.unsupportedQuantityCode(linkID: "weight", code: "rad")) {
            _ = try QuestionnaireDataExtractor(response: response).quantitySample(
                SampleType<HKQuantitySample>.bodyMass,
                linkID: "weight"
            )
        }
    }

    @Test
    func quantityRejectsCatalogUnitThatIsIncompatibleWithSampleType() throws {
        let responseJSON = Data(#"""
        {
          "resourceType":"QuestionnaireResponse",
          "status":"completed",
          "authored":"2026-08-29T12:00:00-07:00",
          "item":[{
            "linkId":"weight",
            "answer":[{"valueQuantity":{"value":37,"system":"http://unitsofmeasure.org","code":"Cel"}}]
          }]
        }
        """#.utf8)
        let response = try JSONDecoder().decode(QuestionnaireResponse.self, from: responseJSON)

        #expect(throws: QuestionnaireDataExtractionError.incompatibleQuantityUnit(linkID: "weight", code: "Cel")) {
            _ = try QuestionnaireDataExtractor(response: response).quantitySample(
                SampleType<HKQuantitySample>.bodyMass,
                linkID: "weight"
            )
        }
    }
}
