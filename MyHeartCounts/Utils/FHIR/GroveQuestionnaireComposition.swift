//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Darwin
import Foundation
import GroveQuestionnaire
import GroveQuestionnaireFHIR
import ModelsR4


/// Application and host facts captured with a QuestionnaireResponse.
struct QuestionnaireResponseWriterContext: Equatable, Sendable {
    enum PreparationError: Error, Equatable {
        case missingApplicationIdentifier
        case missingApplicationName
        case missingApplicationVersion
    }

    let applicationIdentifier: String
    let applicationName: String
    let applicationVersion: String
    let applicationBuild: String?
    let hostModel: String?
    let hostOperatingSystemVersion: String

    static func current(
        bundle: Foundation.Bundle = .main,
        processInfo: ProcessInfo = .processInfo
    ) throws -> Self {
        guard let identifier = bundle.bundleIdentifier, !identifier.isEmpty else {
            throw PreparationError.missingApplicationIdentifier
        }
        let info = bundle.infoDictionary ?? [:]
        guard let name = (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String,
              !name.isEmpty else {
            throw PreparationError.missingApplicationName
        }
        guard let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty else {
            throw PreparationError.missingApplicationVersion
        }
        let operatingSystemVersion = processInfo.operatingSystemVersion
        return Self(
            applicationIdentifier: identifier,
            applicationName: name,
            applicationVersion: version,
            applicationBuild: (info["CFBundleVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            hostModel: hostModel(processInfo: processInfo),
            hostOperatingSystemVersion: [
                operatingSystemVersion.majorVersion,
                operatingSystemVersion.minorVersion,
                operatingSystemVersion.patchVersion
            ].map(String.init).joined(separator: ".")
        )
    }

    private static func hostModel(processInfo: ProcessInfo) -> String? {
        if let simulatedModel = processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
           !simulatedModel.isEmpty {
            return simulatedModel
        }
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else {
            return nil
        }
        let capacity = MemoryLayout.size(ofValue: systemInfo.machine)
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(validatingCString: $0)
            }
        }.flatMap { $0.isEmpty ? nil : $0 }
    }
}


extension QuestionnaireResponse {
    private static let applicationIdentifierSystem =
        "https://myheartcounts.stanford.edu/fhir/identifiers/application"
    private static let writerContextURL =
        "https://grovealliance.org/fhir/questionnaire/StructureDefinition/grove-questionnaire-writer-context"

    var questionnaireCanonicalBaseURL: String? {
        guard let canonical = questionnaire?.value?.url.absoluteString else {
            return nil
        }
        return canonical.split(separator: "|", maxSplits: 1).first.map(String.init)
    }

    private static func writerContext(_ context: QuestionnaireResponseWriterContext) -> Extension {
        var children = [
            Extension(
                url: FHIRPrimitive(FHIRURI(stringLiteral: "applicationIdentifier")),
                value: .identifier(Identifier(
                    system: FHIRPrimitive(FHIRURI(stringLiteral: applicationIdentifierSystem)),
                    value: context.applicationIdentifier.asFHIRStringPrimitive()
                ))
            ),
            Extension(
                url: FHIRPrimitive(FHIRURI(stringLiteral: "applicationName")),
                value: .string(context.applicationName.asFHIRStringPrimitive())
            ),
            Extension(
                url: FHIRPrimitive(FHIRURI(stringLiteral: "applicationVersion")),
                value: .string(context.applicationVersion.asFHIRStringPrimitive())
            )
        ]
        if let build = context.applicationBuild {
            children.append(Extension(
                url: FHIRPrimitive(FHIRURI(stringLiteral: "applicationBuild")),
                value: .string(build.asFHIRStringPrimitive())
            ))
        }
        if let hostModel = context.hostModel {
            children.append(Extension(
                url: FHIRPrimitive(FHIRURI(stringLiteral: "hostModel")),
                value: .string(hostModel.asFHIRStringPrimitive())
            ))
        }
        children.append(Extension(
            url: FHIRPrimitive(FHIRURI(stringLiteral: "hostOperatingSystemVersion")),
            value: .string(context.hostOperatingSystemVersion.asFHIRStringPrimitive())
        ))
        return Extension(
            extension: children,
            url: FHIRPrimitive(FHIRURI(stringLiteral: writerContextURL))
        )
    }

    /// Adds the capture facts required by the Grove writer-context extension.
    mutating func apply(writerContext context: QuestionnaireResponseWriterContext) {
        var extensions = self.extension ?? []
        extensions.removeAll { $0.url.value?.url.absoluteString == Self.writerContextURL }
        extensions.append(Self.writerContext(context))
        self.extension = extensions
    }
}


extension ModelsR4.Questionnaire {
    /// Converts a catalog resource into Grove's native questionnaire model.
    func groveQuestionnaire(
        evaluationInstant: Date,
        locale: Locale = .autoupdatingCurrent
    ) throws -> GroveQuestionnaire.Questionnaire {
        try GroveQuestionnaire.Questionnaire(
            self,
            evaluationInstant: evaluationInstant,
            using: .init(locale: locale)
        )
    }
}
