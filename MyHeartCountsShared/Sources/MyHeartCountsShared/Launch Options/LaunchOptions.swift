//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

#if !os(Linux)

// swiftlint:disable file_types_order
// periphery:ignore:all

public import Foundation
private import os
private import Synchronization


// MARK: API

/// A Value that can be decoded from a parameter passed to the program's launch options (argv).
public protocol LaunchOptionDecodable: Sendable {
    /// Attempts to construct a value of the type, by decoding the raw arguments that were passed to this launch option.
    init(decodingLaunchOption context: LaunchOptionDecodingContext) throws
}

public struct LaunchOptionDecodingContext: Sendable {
    public enum NumRawArgsCondition: Sendable {
        case atLeast(Int)
        case equal(Int)
        case atMost(Int)
        
        fileprivate func isSatisfied(by numArgs: Int) -> Bool {
            switch self {
            case .atLeast(let numExpected):
                return numExpected <= numArgs
            case .equal(let numExpected):
                return numExpected == numArgs
            case .atMost(let numExpected):
                return numExpected >= numArgs
            }
        }
    }
    
    public let rawArgs: [String]
    
    /// Checks that the number of raw args satisfies the specified condition.
    /// Throws an exception, if not.
    public func assertNumRawArgs(_ condition: NumRawArgsCondition) throws {
        guard condition.isSatisfied(by: rawArgs.count) else {
            throw LaunchOptionDecodingError.invalidNumArguments(expected: condition, actual: rawArgs.count)
        }
    }
}


public protocol LaunchOptionsContainerProtocol: Sendable {
    func _value<V>(for option: LaunchOption<V>) -> V? // swiftlint:disable:this identifier_name
}

extension LaunchOptionsContainerProtocol {
    /// Returns the specified `option`'s decoded launch option argument, falling back to its default value if no argument was specified.
    public subscript<V>(option: LaunchOption<V>) -> V {
        _value(for: option) ?? option.makeDefault()
    }
}


public class LaunchOptions: @unchecked Sendable {
    fileprivate init() {}
}

public final class LaunchOption<Value: LaunchOptionDecodable>: LaunchOptions, @unchecked Sendable {
    public let key: String
    fileprivate let makeDefault: @Sendable () -> Value
    fileprivate let _parsedValue = Mutex<Value?>(nil)
    
    public init(_ key: String, default makeDefault: @autoclosure @escaping @Sendable () -> Value) {
        self.key = key
        self.makeDefault = makeDefault
        super.init()
    }
}


/// An error that can occur when decoding and processing launch options.
public enum LaunchOptionDecodingError: Error, LocalizedError {
    /// Decoding a ``LaunchOptionDecodable`` type failed
    /// - parameter type: The type we attempted to decode a value of.
    /// - parameter rawValue: The raw value we attempted to decode, as passed to the launch arguments.
    case unableToDecode(_ type: any LaunchOptionDecodable.Type, rawValue: String)
    
    /// A launch option was supplied an incorrect number of arguments
    case invalidNumArguments(expected: LaunchOptionDecodingContext.NumRawArgsCondition, actual: Int)
    
    case other(_ message: String)
    
    public var errorDescription: String? {
        switch self {
        case let .unableToDecode(type, rawValue):
            "Unable to decode \(type) from launch option value '\(rawValue)'"
        case let .invalidNumArguments(.equal(expected), actual):
            "Invalid number of arguments passed to launch option: got \(actual), expected \(expected)"
        case let .invalidNumArguments(.atLeast(expected), actual):
            "Invalid number of arguments passed to launch option: got \(actual), expected at least \(expected)"
        case let .invalidNumArguments(.atMost(expected), actual):
            "Invalid number of arguments passed to launch option: got \(actual), expected at most \(expected)"
        case .other(let message):
            message
        }
    }
}


/// A type that can be encoded into an array of launch option arguments.
public protocol LaunchOptionEncodable: LaunchOptionDecodable {
    /// The raw argv values that represent this launch option.
    ///
    /// - Note: You are responsible for including the launch option's key as the first element in the array.
    ///     If the receiver's value represents an empty value or does not have a launch option arguments representation,
    ///     you can simply return an empty array.
    func launchOptionArgs(for launchOption: LaunchOption<Self>) -> [String]
}


// MARK: Implementation

private struct ParsedLaunchOptionArguments {
    /// The first argument, i.e. the program name
    var programName: String = ""
    /// Any positional arguments that come directly after the program name, and before any option (i.e., `-`-prefixed) arguments.
    /// - Note: alternative name: positionalArguments
    var directProgramArguments: [String] = []
    /// Any option arguments. This dictionary contains as its keys the options, and as its values any subsequent arguments that followed the option.
    var options: [String: [String]] = [:]
}


extension LaunchOptionsContainerProtocol {
    /// Creates a new launch options container by chaining the container after another one.
    public func prepending(_ other: some LaunchOptionsContainerProtocol) -> some LaunchOptionsContainerProtocol {
        CombinedLaunchOptionsContainer(containers: [other, self])
    }
}

private struct CombinedLaunchOptionsContainer: LaunchOptionsContainerProtocol {
    let containers: [any LaunchOptionsContainerProtocol]
    
    func _value<V>(for option: LaunchOption<V>) -> V? { // swiftlint:disable:this identifier_name
        for container in containers {
            if let value = container._value(for: option) {
                return value
            }
        }
        return nil
    }
}


extension LaunchOptions {
    /// The CLI launch options passed to the current program.
    public static let launchOptions: any LaunchOptionsContainerProtocol = LaunchOptions.commandLineOptionsContainer(for: CommandLine.arguments)
    
    /// Creates a container for parsing launch options from from an array of CLI launch options.
    public static func commandLineOptionsContainer(for arguments: [String]) -> some LaunchOptionsContainerProtocol {
        CommandLineLaunchOptionsContainer(arguments: arguments)
    }
    
    /// Creates a container for parsing launch options from from a URL query string.
    public static func urlQuerlOptionsContainer(for components: URLComponents) -> some LaunchOptionsContainerProtocol {
        guard let queryItems = components.queryItems else {
            return commandLineOptionsContainer(for: [])
        }
        let queryItemNameToLaunchOptionName = { (name: String) -> String in
            name.reduce(into: "--") { name, char in
                if char.isUppercase {
                    name.append("-\(char.lowercased())")
                } else {
                    name.append(char)
                }
            }
        }
        var arguments = Array(CommandLine.arguments.prefix(2))
        for queryItem in queryItems {
            arguments.append(queryItemNameToLaunchOptionName(queryItem.name))
            if let value = queryItem.value {
                // what if this LaunchOption expects multiple args? how would we split up the value?
                arguments.append(value)
            }
        }
        return commandLineOptionsContainer(for: arguments)
    }
    
    /// Returns the specified `option`'s decoded launch option argument, falling back to its default value if no argument was specified.
    public static subscript<V>(option: LaunchOption<V>) -> V {
        Self.launchOptions[option]
    }
}


private struct CommandLineLaunchOptionsContainer: LaunchOptionsContainerProtocol {
    private let parsedArguments: ParsedLaunchOptionArguments
    
    /// Creates a new `CommandLineLaunchOptions` instance for the specified arguments array.
    /// - Note: The first element in `arguments` will be assumed to be the executable name, and will always be skipped.
    init(arguments: [String] = CommandLine.arguments) {
        guard !arguments.isEmpty else {
            self.parsedArguments = .init()
            return
        }
        var remainingArgs = arguments[...]
        var parsedArguments = ParsedLaunchOptionArguments()
         
        // Parse program name (argv[0])
        parsedArguments.programName = remainingArgs.first! // swiftlint:disable:this force_unwrapping
        remainingArgs.removeFirst()
        
        // Parse program positional args (ie, the non-options that come directly after the program name)
        parsedArguments.directProgramArguments = Array(remainingArgs.prefix { !$0.starts(with: "-") })
        remainingArgs.removeFirst(parsedArguments.directProgramArguments.count)
        
        // Process remaining options
        while !remainingArgs.isEmpty {
            let optionName = remainingArgs.removeFirst()
            precondition(optionName.starts(with: "-")) // if this fails, the parser has an error somewhere
            let optionArgs = Array(remainingArgs.prefix { !$0.starts(with: "-") })
            remainingArgs.removeFirst(optionArgs.count)
            parsedArguments.options[optionName] = optionArgs
        }
        
        self.parsedArguments = parsedArguments
        
        if self[.dumpOptionsAndExit] {
            var summary = "Found CLI flag '\(LaunchOptions.dumpOptionsAndExit.key)'."
            summary += "\nCLI Options:"
            summary += "\n- programName: \(parsedArguments.programName)"
            summary += "\n- directProgramArguments: \(parsedArguments.directProgramArguments)"
            summary += "\n- options:"
            for (key, values) in parsedArguments.options {
                summary += "\n  [\(key)] = \(values)"
            }
            print(summary)
            exit(EXIT_SUCCESS)
        }
    }
    
    
    func _value<V>(for option: LaunchOption<V>) -> V? { // swiftlint:disable:this identifier_name
        option._parsedValue.withLock { value in
            if let value {
                return value
            }
            guard let optionRawArgs = parsedArguments.options[option.key] else {
                return nil
            }
            do {
                value = try V(decodingLaunchOption: LaunchOptionDecodingContext(rawArgs: optionRawArgs))
                return value
            } catch {
                print("Unable to parse value for option '\(option.key)': \(error)")
                return nil
            }
        }
    }
}


// MARK: LaunchOptionDecodable conformances

extension Int: LaunchOptionDecodable {}
extension UInt: LaunchOptionDecodable {}
extension Int8: LaunchOptionDecodable {}
extension Int16: LaunchOptionDecodable {}
extension Int32: LaunchOptionDecodable {}
extension Int64: LaunchOptionDecodable {}
extension UInt8: LaunchOptionDecodable {}
extension UInt16: LaunchOptionDecodable {}
extension UInt32: LaunchOptionDecodable {}
extension UInt64: LaunchOptionDecodable {}
extension Float: LaunchOptionDecodable {}
extension Double: LaunchOptionDecodable {}
extension String: LaunchOptionDecodable {}

extension Bool: LaunchOptionDecodable, LaunchOptionEncodable {
    public init(decodingLaunchOption context: LaunchOptionDecodingContext) throws {
        try context.assertNumRawArgs(.atMost(1))
        switch context.rawArgs.first?.lowercased() {
        case nil:
            // if the option (/flag) exists but has no value,
            // we implicitly set it to true (to indicate its presence)
            self = true
        case "true", "yes", "y", "1":
            self = true
        case "false", "no", "n", "0":
            self = false
        case .some(let rawValue):
            throw LaunchOptionDecodingError.unableToDecode(Self.self, rawValue: rawValue)
        }
    }
    
    public func launchOptionArgs(for launchOption: LaunchOption<Bool>) -> [String] {
        self ? [launchOption.key] : []
    }
}

extension LosslessStringConvertible where Self: LaunchOptionDecodable {
    public init(decodingLaunchOption context: LaunchOptionDecodingContext) throws { // swiftlint:disable:this missing_docs
        try context.assertNumRawArgs(.equal(1))
        let rawValue = context.rawArgs[0]
        if let value = Self(rawValue) {
            self = value
        } else {
            throw LaunchOptionDecodingError.unableToDecode(Self.self, rawValue: rawValue)
        }
    }
}

extension RawRepresentable where RawValue: LosslessStringConvertible, Self: LaunchOptionDecodable {
    public init(decodingLaunchOption context: LaunchOptionDecodingContext) throws { // swiftlint:disable:this missing_docs
        try context.assertNumRawArgs(.equal(1))
        let rawValue = context.rawArgs[0]
        if let rawValue = RawValue(rawValue), let value = Self(rawValue: rawValue) {
            self = value
        } else {
            throw LaunchOptionDecodingError.unableToDecode(Self.self, rawValue: rawValue)
        }
    }
}

extension URL: LaunchOptionDecodable, LaunchOptionEncodable {
    public init(decodingLaunchOption context: LaunchOptionDecodingContext) throws {
        try context.assertNumRawArgs(.equal(1))
        self = try .decodeAsLaunchOptionValue(rawValue: context.rawArgs[0])
    }
    
    private static func decodeAsLaunchOptionValue(
        rawValue: String,
        fileUrlBasePath: URL = .documentsDirectory
    ) throws -> URL {
        if rawValue.starts(with: /https?/) {
            // Treat as internet URL
            if let url = URL(string: rawValue) {
                return url
            } else {
                throw LaunchOptionDecodingError.unableToDecode(Self.self, rawValue: rawValue)
            }
        } else {
            // treat as file URL
            return URL(filePath: rawValue, relativeTo: rawValue.starts(with: "/") ? nil : fileUrlBasePath)
        }
    }
    
    public func launchOptionArgs(for launchOption: LaunchOption<URL>) -> [String] {
        if self.isFileURL {
            [launchOption.key, self.absoluteURL.path(percentEncoded: false)]
        } else {
            [launchOption.key, self.absoluteURL.absoluteString]
        }
    }
}

extension Optional: LaunchOptionDecodable where Wrapped: LaunchOptionDecodable {
    public init(decodingLaunchOption context: LaunchOptionDecodingContext) throws {
        self = .some(try Wrapped(decodingLaunchOption: context))
    }
}

extension Optional: LaunchOptionEncodable where Wrapped: LaunchOptionEncodable {
    public func launchOptionArgs(for launchOption: LaunchOption<Wrapped?>) -> [String] {
        switch self {
        case .none:
            []
        case .some(let value):
            // we need to create a fake LaunchOption here to adjust the generic parameter...
            value.launchOptionArgs(
                for: LaunchOption<Wrapped>(launchOption.key, default: value)
            )
        }
    }
}


// MARK: Debugging

extension LaunchOptions {
    /// A special launch option that, if specified, simply prints all other parsed launch options to STDOUT and then terminates the program.
    public static let dumpOptionsAndExit = LaunchOption<Bool>("--dump-cli-options-and-exit", default: false)
}

#endif
