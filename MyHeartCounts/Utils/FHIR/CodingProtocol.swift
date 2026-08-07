//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import ModelsR4


// Note: we intentionally directly use `FHIRPrimitive`s here (instead of Strings which then get converted when needed);
// the reason being that the `asFHIR{String|URI|etc}Primitive()` operations do take some time on the scale we perform them,
// and it's just way more efficient to only perform this operation once.
//
// Conforming types are strongly encouraged to define their individual codings as non-computed static propertied,
// to betterachieve these performance improvements.
protocol CodingProtocol: Hashable, Sendable {
    static var system: FHIRPrimitive<FHIRURI> { get }
    static var version: FHIRPrimitive<FHIRString>? { get }
    
    var code: FHIRPrimitive<FHIRString> { get }
    var display: FHIRPrimitive<FHIRString>? { get }
}


extension CodingProtocol {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.code == rhs.code
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(code)
    }
}

extension CodingProtocol {
    static var version: FHIRPrimitive<FHIRString>? {
        nil
    }
    
    var system: FHIRPrimitive<FHIRURI> {
        Self.system
    }
    
    var version: FHIRPrimitive<FHIRString>? {
        Self.version
    }
}


// MARK: FHIR Extensions

extension Coding {
    // periphery:ignore:parameters system
    init<C: CodingProtocol>(system: C.Type = C.self, code: C) {
        self.init(
            code: code.code,
            display: code.display,
            system: code.system,
            version: code.version
        )
    }
}

extension CodeableConcept {
    init<C: CodingProtocol>(system: C.Type = C.self, code: C) {
        self.init(coding: [Coding(system: system, code: code)])
    }
}


extension ObservationComponent {
    init<C: CodingProtocol>(
        system: C.Type = C.self,
        code: C,
        value: ObservationComponent.ValueX?
    ) {
        self.init(
            code: CodeableConcept(system: system, code: code),
            value: value
        )
    }
    
    init<C: CodingProtocol>(
        system: C.Type = C.self,
        code: C,
        quantityUnit: String,
        quantityValue: Double
    ) {
        self.init(
            code: code,
            value: .quantity(.init(
                system: system,
                code: code,
                unit: quantityUnit,
                value: quantityValue
            ))
        )
    }
}


extension Quantity {
    // periphery:ignore:parameters system
    init<C: CodingProtocol>(system: C.Type = C.self, code: C, unit: String, value: Double) {
        self.init(
            code: code.code,
            system: code.system,
            unit: unit.asFHIRStringPrimitive(),
            value: value.asFHIRDecimalPrimitive()
        )
    }
}
