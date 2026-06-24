//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order

import FHIRModelsExtensions
import Foundation
import ModelsR4
import SpeziHealthKit


struct QuestionnaireDataExtractor {
    let response: QuestionnaireResponse
    private let allResponses: Set<QuestionnaireResponseItem>
    
    init(response: QuestionnaireResponse) {
        self.response = response
        self.allResponses = response.allResponses
    }
    
    func answer(to questionLinkId: String) -> QuestionnaireResponseItemAnswer? {
        let responses = allResponses.filter { $0.linkId.value?.string == questionLinkId }
        guard responses.count <= 1 else {
            print("Found multiple responses for question \(questionLinkId)")
            return nil
        }
        guard let answers = responses.first?.answer else {
            return nil
        }
        guard answers.count <= 1 else {
            print("Found multiple answers in response for question \(questionLinkId)")
            return nil
        }
        return answers.first
    }
}


extension QuestionnaireDataExtractor {
    protocol AnyRule<Context>: Sendable {
        associatedtype Context: Sendable
        associatedtype Output: Sendable
        func callAsFunction(
            isolation: isolated (any Actor)?,
            extractor: QuestionnaireDataExtractor,
            context: Context
        ) async throws -> Output
    }
    
    
    struct Rule<Context: Sendable, Output: Sendable>: AnyRule {
        typealias Imp = @Sendable (
            _ isolation: isolated (any Actor)?,
            _ extractor: QuestionnaireDataExtractor,
            _ context: Context
        ) async throws -> Output
        
        private let imp: Imp
        
        init(_ imp: @escaping Imp) {
            self.imp = imp
        }
        
        @discardableResult
        func callAsFunction(
            isolation: isolated (any Actor)? = #isolation,
            extractor: QuestionnaireDataExtractor,
            context: Context
        ) async throws -> Output {
            try await imp(isolation, extractor, context)
        }
    }
}


extension QuestionnaireDataExtractor.Rule {
    /// A rule that extracts a quanity answer, turns it into an `HKQuantitySample`, and saves that to HealthKit.
    static func quantitySample(
        _ sampleType: SampleType<HKQuantitySample>,
        linkId: String
    ) -> Self where Context == HealthKit, Output == HKQuantitySample? {
        Self { _, extractor, healthKit in
            switch extractor.answer(to: linkId)?.value {
            case .quantity(let quantity):
                guard let value = quantity.value?.value?.decimal.doubleValue,
                      let unit = quantity.unit?.value?.string,
                      let unit = HKUnit.parse(unit) else {
                    return nil
                }
                let date = (try? extractor.response.authored?.value?.asNSDate()) ?? .now
                let sample = HKQuantitySample(
                    type: sampleType.hkSampleType,
                    quantity: HKQuantity(unit: unit, doubleValue: value),
                    start: date,
                    end: date
                )
                try await healthKit.save(sample)
                return sample
            default:
                return nil
            }
        }
    }
    
    /// A rule that extracts quanity answers for systolic and diastolic blood pressure, turns these into an `HKCorrelation`, and saves that to HealthKit.
    static func bloodPressure(
        systolicLinkId: String,
        diastolicLinkId: String
    ) -> Self where Context == HealthKit, Output == Void {
        Self { isolation, extractor, healthKit in
            let systolic = try? await QuestionnaireDataExtractor.Rule.quantitySample(
                .bloodPressureSystolic,
                linkId: systolicLinkId
            )(isolation: isolation, extractor: extractor, context: healthKit)
            let diastolic = try? await QuestionnaireDataExtractor.Rule.quantitySample(
                .bloodPressureDiastolic,
                linkId: diastolicLinkId
            )(isolation: isolation, extractor: extractor, context: healthKit)
            if let systolic, let diastolic {
                let correlation = HKCorrelation(
                    type: SampleType.bloodPressure.hkSampleType,
                    start: min(systolic.startDate, diastolic.startDate),
                    end: max(systolic.endDate, diastolic.endDate),
                    objects: [systolic, diastolic]
                )
                try await healthKit.save(correlation)
            }
        }
    }
}


private protocol QuestionnaireResponseItemContainer {
    var item: [QuestionnaireResponseItem]? { get } // swiftlint:disable:this discouraged_optional_collection
}

extension QuestionnaireResponse: QuestionnaireResponseItemContainer {}
extension QuestionnaireResponseItem: QuestionnaireResponseItemContainer {}
extension QuestionnaireResponseItemAnswer: QuestionnaireResponseItemContainer {}

extension QuestionnaireResponseItemContainer {
    var allResponses: Set<QuestionnaireResponseItem> {
        var responses = Set(self.item ?? [])
        for response in responses {
            responses.formUnion(response.allResponses)
        }
        return responses
    }
}
