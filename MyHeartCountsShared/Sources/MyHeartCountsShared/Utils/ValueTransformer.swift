//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order


/// A type that transforms a value into another value.
///
/// Equal transformers must produce equivalent results for the same input.
/// All configuration affecting the transformation must participate in equality.
/// Implementations must not depend on mutable external state that isn't
/// represented by that configuration.
public protocol ValueTransformer<Input, Output>: Hashable, Sendable {
    /// The input type.
    associatedtype Input
    
    /// The output type.
    associatedtype Output
    
    /// Transforms a value
    func transform(_ input: Input) throws -> Output
}


// MARK: Concat

extension ValueTransformer {
    /// Chains two value transformers.
    public func concat<NewOutput>(_ other: some ValueTransformer<Self.Output, NewOutput>) -> some ValueTransformer<Self.Input, NewOutput> {
        ConcatValueTransformer(fst: self, snd: other)
    }
}


private struct ConcatValueTransformer<Fst: ValueTransformer, Snd: ValueTransformer>: ValueTransformer<Fst.Input, Snd.Output>
where Fst.Output == Snd.Input {
    let fst: Fst
    let snd: Snd
    
    func transform(_ input: Fst.Input) throws -> Snd.Output {
        try snd.transform(fst.transform(input))
    }
}
