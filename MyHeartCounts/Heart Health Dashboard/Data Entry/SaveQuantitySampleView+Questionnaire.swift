//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HealthKit
import ModelsR4
import MyHeartCountsShared
import SpeziFoundation
import SpeziHealthKit
import SpeziHealthKitFHIR


nonisolated extension SaveQuantitySampleView {
    enum Input {
        case quantity(QuantitySample)
        case bloodPressure(BloodPressureMeasurement)
        case bmi(bmi: Double, measurements: (height: HKQuantity, weight: HKQuantity)?)
    }


    private static let hkQuantitySampleTypeShortIds: [SampleType<HKQuantitySample>: String] = [
        .height: "height",
        .bodyMass: "weight",
        .bodyMassIndex: "bmi",
        .bloodGlucose: CustomQuantitySampleType.bloodGlucoseFasting.shortId
    ]

    fileprivate static func sampleTypeIdentifier(for input: Input) -> String {
        switch input {
        case .bloodPressure:
            return "blood-pressure"
        case .bmi:
            return "bmi"
        case .quantity(let sample):
            switch sample.sampleType {
            case .custom(let sampleType):
                return sampleType.shortId
            case .healthKit(let sampleType):
                if let id = hkQuantitySampleTypeShortIds[sampleType] {
                    return id
                } else {
                    assertionFailure("Missing short-id mapping for HK type \(sampleType). Returning full HK id as fallback")
                    return sampleType.id
                }
            }
        }
    }

    static func questionnaireUrl(for input: Input) -> URL {
        "https://myheartcounts.stanford.edu/fhir/survey/\(sampleTypeIdentifier(for: input))"
    }

    /// Creates a R4 `QuestionnaireResponse` for user-provided data entered via the dashboard.
    static func singleSampleDataEntryQuestionnaireResponse(
        for input: Input
    ) throws -> ModelsR4.QuestionnaireResponse {
        // NOTE: this currently is implemented by directly creating a FHIR QuestionnaireResponse,
        // (instead of using SpeziQuestionnaire to construct a questionnaire and creating a response for that),
        // the reason being that SpeziQuestionnaire's `QuestionnaireResponses.responses` setter is not yet public,
        // meaning that we can't manually construct such response objects, and we also currently can't easily
        // fix that in Spezi (since the main branch contains a bunch of unreleased breaking changes, eg the Grove rename).
        // so what we do instead is that for the time being we costruct the QuestionnaireResponse manually,
        // and we will eventually switch over to the better approach.
        // the resulting questionnaires should be functionally equivalent.
        let id = UUID().uuidString.asFHIRStringPrimitive()
        let url = questionnaireUrl(for: input)
        return QuestionnaireResponse(
            authored: FHIRPrimitive(try? DateTime(date: .now)),
            id: id,
            identifier: Identifier(value: id),
            item: try toItems(input),
            language: nil,
            questionnaire: FHIRPrimitive(Canonical(url)),
            status: FHIRPrimitive(.completed)
        )
    }


    @ArrayBuilder<QuestionnaireResponseItem>
    private static func toItems(_ input: Input) throws -> [QuestionnaireResponseItem] { // swiftlint:disable:this function_body_length
        switch input {
        case .quantity(let quantity):
            QuestionnaireResponseItem(
                answer: [
                    QuestionnaireResponseItemAnswer(
                        value: .quantity(try quantity.toFHIRQuantity())
                    )
                ],
                linkId: sampleTypeIdentifier(for: input).asFHIRStringPrimitive()
            )
        case .bloodPressure(let measurement):
            QuestionnaireResponseItem(
                item: [
                    QuestionnaireResponseItem(
                        answer: [
                            QuestionnaireResponseItemAnswer(
                                value: .quantity(Quantity(
                                    unit: .mmHg,
                                    value: Double(measurement.systolic)
                                ))
                            )
                        ],
                        linkId: "blood-pressure-systolic"
                    ),
                    QuestionnaireResponseItem(
                        answer: [
                            QuestionnaireResponseItemAnswer(
                                value: .quantity(Quantity(
                                    unit: .mmHg,
                                    value: Double(measurement.diastolic)
                                ))
                            )
                        ],
                        linkId: "blood-pressure-diastolic"
                    )
                ],
                linkId: "blood-pressure"
            )
        case let .bmi(bmi, measurements):
            // the link ids used here must match the item structure of `ModelsR4.Questionnaire.bmi`.
            let mode: ModelsR4.Questionnaire.BMIModeCodingSystem = measurements == nil ? .direct : .compute
            QuestionnaireResponseItem(
                answer: [
                    QuestionnaireResponseItemAnswer(value: .coding(Coding(code: mode)))
                ],
                linkId: "mode"
            )
            if let measurements {
                QuestionnaireResponseItem(
                    item: [
                        QuestionnaireResponseItem(
                            answer: [
                                QuestionnaireResponseItemAnswer(
                                    value: .quantity(Quantity(
                                        unit: .centimeter,
                                        value: measurements.height.doubleValue(for: .meterUnit(with: .centi))
                                    ))
                                )
                            ],
                            linkId: "height"
                        ),
                        QuestionnaireResponseItem(
                            answer: [
                                QuestionnaireResponseItemAnswer(
                                    value: .quantity(Quantity(
                                        unit: .kilogram,
                                        value: measurements.weight.doubleValue(for: .gramUnit(with: .kilo))
                                    ))
                                )
                            ],
                            linkId: "weight"
                        )
                    ],
                    linkId: "measurements"
                )
            } else {
                QuestionnaireResponseItem(
                    answer: [
                        QuestionnaireResponseItemAnswer(value: .decimal(bmi.asFHIRDecimalPrimitive()))
                    ],
                    linkId: "bmi-entered"
                )
            }
            // the `bmi` item is the questionnaire's read-only, calculated result; we always include it,
            // regardless of whether the value was entered directly or computed from the weight and height.
            QuestionnaireResponseItem(
                answer: [
                    QuestionnaireResponseItemAnswer(value: .decimal(bmi.asFHIRDecimalPrimitive()))
                ],
                linkId: "bmi"
            )
        }
    }
}


extension UCUM {
    static let kgPerM2 = UCUM(code: "kg/m2", unit: "kg/m2", display: "kg/m²")
    static let centimeter = UCUM(code: "cm", unit: "cm", display: "cm")
    static let kilogram = UCUM(code: "kg", unit: "kg", display: "kg")
}


extension LOINC {
    fileprivate static let bodyHeight = LOINC("8302-2")
    fileprivate static let bodyWeight = LOINC("29463-7")
    fileprivate static let bodyMassIndex = LOINC("39156-5")
}


extension QuantitySample {
    fileprivate func toFHIRQuantity() throws -> Quantity {
        switch sampleType {
        case .healthKit(let sampleType):
            let hkSample = HKQuantitySample(
                type: sampleType.hkSampleType,
                quantity: self.hkQuantity(),
                start: self.startDate,
                end: self.endDate
            )
            let resource = try hkSample.resource()
            guard let observation = resource.get(if: Observation.self) else {
                throw NSError(localizedDescription: "Unable to obtain Observation")
            }
            switch observation.value {
            case .quantity(let quantity):
                return quantity
            default:
                throw NSError(localizedDescription: "Unable to obtain Quantity")
            }
        case .custom(let sampleType):
            return Quantity(
                unit: sampleType.canonicalUnitUCUM,
                value: self.value(as: sampleType.canonicalUnit)
            )
        }
    }
}


extension ModelsR4.Questionnaire {
    struct BMIModeCodingSystem: CodingProtocol {
        static let system: FHIRPrimitive<FHIRURI> = "https://myheartcounts.stanford.edu/fhir/bmi-entry"

        static let direct = Self("direct", display: "Direct")
        static let compute = Self("compute", display: "Weight + Height")

        let code: FHIRPrimitive<FHIRString>
        let display: FHIRPrimitive<FHIRString>?

        init(_ code: FHIRPrimitive<FHIRString>, display: FHIRPrimitive<FHIRString>? = nil) {
            self.code = code
            self.display = display
        }
    }


    static let bmi = Self(
        item: [
            QuestionnaireItem(
                answerOption: [
                    QuestionnaireItemAnswerOption(value: .coding(Coding(code: BMIModeCodingSystem.direct))),
                    QuestionnaireItemAnswerOption(value: .coding(Coding(code: BMIModeCodingSystem.compute)))
                ],
                linkId: "mode",
                text: "How do you want to enter your BMI?", // TODO translate!
                type: FHIRPrimitive(.choice)
            ),

            QuestionnaireItem(
                enableWhen: [
                    QuestionnaireItemEnableWhen(
                        answer: .coding(Coding(code: BMIModeCodingSystem.direct)),
                        operator: FHIRPrimitive(.equal),
                        question: "mode"
                    )
                ],
                extension: [.questionnaireUnit(.kgPerM2)],
                linkId: "bmi-entered",
                text: "BMI",
                type: FHIRPrimitive(.decimal)
            ),

            QuestionnaireItem(
                enableWhen: [
                    QuestionnaireItemEnableWhen(
                        answer: .coding(Coding(code: BMIModeCodingSystem.compute)),
                        operator: FHIRPrimitive(.equal),
                        question: "mode"
                    )
                ],
                item: [
                    QuestionnaireItem(
                        code: [Coding(code: LOINC.bodyHeight)],
                        extension: [.questionnaireUnitOption(.centimeter)],
                        linkId: "height",
                        text: "Height",
                        type: FHIRPrimitive(.quantity)
                    ),
                    QuestionnaireItem(
                        code: [Coding(code: LOINC.bodyWeight)],
                        extension: [.questionnaireUnitOption(.kilogram)],
                        linkId: "weight",
                        text: "Weight",
                        type: FHIRPrimitive(.quantity)
                    )
                ],
                linkId: "measurements",
                type: FHIRPrimitive(.group)
            ),

            QuestionnaireItem(
                code: [Coding(code: LOINC.bodyMassIndex)],
                extension: [
                    .questionnaireUnit(.kgPerM2),
                    .observationExtract(true),
                    .variable(name: "mode", expression: "%resource.item.where(linkId='mode').answer.value.code"),
                    .variable(name: "entered", expression: "%resource.item.where(linkId='bmi-entered').answer.value"),
                    .variable(name: "h", expression: "%resource.repeat(item).where(linkId='height').answer.value.value"),
                    .variable(name: "w", expression: "%resource.repeat(item).where(linkId='weight').answer.value.value"),
                    .calculatedExpression("iif(%mode = 'direct', %entered, (%w / ((%h / 100).power(2))).round(1))")
                ],
                linkId: "bmi",
                readOnly: true,
                text: "BMI",
                type: FHIRPrimitive(.decimal)
            )
        ],
        status: FHIRPrimitive(.active),
        title: "BMI",
        url: "https://myheartcounts.stanford.edu/fhir/survey/bmi"
    )
}


extension ModelsR4.Extension {
    /// The unit an item's value is in. Applicable to `decimal` and `integer` items.
    fileprivate static func questionnaireUnit(_ unit: UCUM) -> Self {
        Self(
            url: "http://hl7.org/fhir/StructureDefinition/questionnaire-unit",
            value: .coding(Coding(code: unit))
        )
    }

    /// One of the units a `quantity` item's value may be entered in.
    fileprivate static func questionnaireUnitOption(_ unit: UCUM) -> Self {
        Self(
            url: "http://hl7.org/fhir/StructureDefinition/questionnaire-unitOption",
            value: .coding(Coding(code: unit))
        )
    }

    /// Whether an `Observation` should be extracted from the item's answer.
    fileprivate static func observationExtract(_ value: FHIRPrimitive<FHIRBool>) -> Self {
        Self(
            url: "http://hl7.org/fhir/uv/sdc/StructureDefinition/sdc-questionnaire-observationExtract",
            value: .boolean(value)
        )
    }

    /// A named FHIRPath expression, which can be referenced (as `%name`) from other expressions on the same item.
    fileprivate static func variable(name: FHIRPrimitive<FHIRString>, expression: FHIRPrimitive<FHIRString>) -> Self {
        Self(
            url: "http://hl7.org/fhir/StructureDefinition/variable",
            value: .expression(Expression(expression: expression, language: "text/fhirpath", name: name))
        )
    }

    /// A FHIRPath expression which computes the item's answer.
    fileprivate static func calculatedExpression(_ expression: FHIRPrimitive<FHIRString>) -> Self {
        Self(
            url: "http://hl7.org/fhir/uv/sdc/StructureDefinition/sdc-questionnaire-calculatedExpression",
            value: .expression(Expression(expression: expression, language: "text/fhirpath"))
        )
    }
}
