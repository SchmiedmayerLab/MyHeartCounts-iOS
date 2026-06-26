//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// periphery:ignore:all - API

public import Algorithms
public import Foundation


extension RangeReplaceableCollection {
    /// Creates a new Collection, containing of the receiver's elements and the elements of some other sequence.
    @inlinable
    public func appending(contentsOf other: some Sequence<Element>) -> Self {
        var copy = self
        copy.append(contentsOf: other)
        return copy
    }
}


extension URL: @retroactive ExpressibleByStringLiteral, @retroactive ExpressibleByStringInterpolation {
    /// Creates a `URL` from a `String` literal.
    @inlinable
    public init(stringLiteral value: String) {
        if let url = URL(string: value) {
            self = url
        } else {
            fatalError("Unable to create URL from string '\(value)'")
        }
    }
}


extension StringProtocol {
    /// Returns a `Substring` with the receiver's leading and trailing whitespace removed
    @inlinable
    public func trimmingLeadingAndTrailingWhitespace() -> SubSequence {
        trimmingLeadingWhitespace().trimmingTrailingWhitespace()
    }
    
    /// Returns a `Substring` with the receiver's leading whitespace removed
    @inlinable
    public func trimmingLeadingWhitespace() -> SubSequence {
        drop(while: \.isWhitespace)
    }
    
    /// Returns a `Substring` with the receiver's trailing whitespace removed
    @inlinable
    public func trimmingTrailingWhitespace() -> SubSequence {
        if let last = self.last, last.isWhitespace {
            dropLast().trimmingTrailingWhitespace()
        } else {
            self[...]
        }
    }
}


extension Sequence {
    /// Determines the largest element of the sequence, based on comparison of a property of the element.
    @inlinable
    public func max(by keyPath: KeyPath<Element, some Comparable>) -> Element? {
        self.max { $0[keyPath: keyPath] < $1[keyPath: keyPath] }
    }
    
    /// Returns the smallest property of the elements of the sequence, based on a key path.
    @inlinable
    public func min<T: Comparable>(of keyPath: KeyPath<Element, T>) -> T? {
        self.min { $0[keyPath: keyPath] < $1[keyPath: keyPath] }?[keyPath: keyPath]
    }
    
    /// Returns the largest property of the elements of the sequence, based on a key path.
    @inlinable
    public func max<T: Comparable>(of keyPath: KeyPath<Element, T>) -> T? {
        self.max { $0[keyPath: keyPath] < $1[keyPath: keyPath] }?[keyPath: keyPath]
    }
}


extension Sequence {
    /// Returns a new sequence that chains the sequence onto the end of the `other` sequence.
    @inlinable
    public func chaining<Other: Sequence<Element>>(after other: Other) -> some Sequence<Element> {
        chain(other, self)
    }
}


extension Int {
    /// Creates an `Int` from a `Decimal` value.
    @inlinable
    public init(_ decimal: Decimal) {
        self = NSDecimalNumber(decimal: decimal).intValue // swiftlint:disable:this legacy_objc_type
    }
}

extension Double {
    /// Creates a `Double` from a `Decimal` value.
    @inlinable
    public init(_ decimal: Decimal) {
        self = NSDecimalNumber(decimal: decimal).doubleValue // swiftlint:disable:this legacy_objc_type
    }
}


extension Sequence {
    /// Calculates the mean (average) over all elements in the Sequence.
    public func mean() -> Element? where Element: BinaryFloatingPoint {
        var iterator = self.makeIterator()
        guard let first = iterator.next() else {
            return nil
        }
        var count = 1
        var avg: Element = first
        while let element = iterator.next() {
            count += 1
            avg += element
        }
        return avg / Element(count)
    }
}


extension Result {
    /// Creates a new result by evaluating a throwing async closure, capturing the
    /// returned value as a success, or any thrown error as a failure.
    ///
    /// - Parameter body: A potentially throwing async closure to evaluate.
    @inlinable
    @_disfavoredOverload
    public init(catchingAsync body: sending () async throws(Failure) -> Success) async {
        do {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }
}
