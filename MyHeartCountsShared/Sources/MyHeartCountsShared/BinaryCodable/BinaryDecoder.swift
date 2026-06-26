//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// periphery:ignore:all - API
// swiftlint:disable missing_docs

public import Foundation
public import NIOCore
public import NIOFoundationCompat


extension BinaryDecoder {
    /// Decodes an instance of `type` from `buffer`.
    @inlinable
    public static func decode<T: BinaryDecodable>(_ type: T.Type, from buffer: ByteBuffer) throws -> T {
        let decoder = BinaryDecoder(buffer: buffer)
        return try type.init(fromBinary: decoder)
    }
    
    /// Decodes an instance of `type` from `data`.
    @inlinable
    public static func decode<T: BinaryDecodable>(_ type: T.Type, from data: some DataProtocol) throws -> T {
        let buffer = ByteBuffer(bytes: data)
        return try decode(type, from: buffer)
    }
}


@usableFromInline
enum BinaryDecodingError: Swift.Error {
    case noData
    case unableToDecodeVarInt(message: String)
    case invalidRawValue(Any.Type, Any.Type, Data)
    case invalidBoolValue(UInt8)
    case other(String)
}


public final class BinaryDecoder {
    @usableFromInline var _buffer: ByteBuffer // swiftlint:disable:this identifier_name
    
    @inlinable public var readableBytes: Int {
        _buffer.readableBytes
    }
    
    @inlinable
    init(buffer: ByteBuffer) {
        self._buffer = buffer
    }
    
    
    @inlinable
    public func decode<T: BinaryDecodable>(_ type: T.Type) throws -> T {
        try type.init(fromBinary: self)
    }
    
    @inlinable
    public func decodeLengthPrefixed<C: RangeReplaceableCollection>(
        lengthType: (some FixedWidthInteger).Type = Int.self,
        _ type: C.Type
    ) throws -> C where C.Element: BinaryDecodable {
        let length = try decodeVarInt(lengthType)
        var result = C()
        result.reserveCapacity(Int(length))
        for _ in 0..<length {
            result.append(try decode(C.Element.self))
        }
        return result
    }
    
    @inlinable
    public func decodeString(length: Int, encoding: String.Encoding = .utf8) throws -> String {
        if let string = _buffer.readString(length: length, encoding: encoding) {
            return string
        } else {
            throw BinaryDecodingError.other("Unable to read string")
        }
    }
    
    
    @inlinable
    public func decodeFullWidthInt<T: FixedWidthInteger>(_: T.Type) throws -> T {
        if let value = _buffer.readInteger(endianness: .big, as: T.self) {
            return value
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unable to read \(T.self)"))
        }
    }
    
    
    /// Reads the value at the current reader index as a VarInt
    /// - returns: the read number, or `nil` if we were unable to read a number (e.g. because there's no data left to be read)
    public func decodeUInt64VarInt() throws -> UInt64 {
        guard _buffer.readableBytes > 0 else {
            throw BinaryDecodingError.noData
        }
        var bytes: [UInt8] = [
            // SAFETY: We know there's at least one byte.
            _buffer.readInteger(endianness: .little, as: UInt8.self)! // swiftlint:disable:this force_unwrapping
        ]
        // SAFETY: we initialize the array with a single element, and then only ever append.
        while (bytes.last! & (1 << 7)) != 0 { // swiftlint:disable:this force_unwrapping
            // we have another byte to parse
            guard let nextByte = _buffer.readInteger(endianness: .little, as: UInt8.self) else {
                throw BinaryDecodingError.unableToDecodeVarInt(
                    message: "Unexpectedly found no byte to read (even though the VarInt's previous byte indicated that there's be one)"
                )
            }
            bytes.append(nextByte)
        }
        precondition(bytes.count <= 10) // maximum length of a var int is 10 bytes, for negative integers
        var result: UInt64 = 0
        for (idx, byte) in bytes.enumerated() { // NOTE that this loop will iterate the VarInt's bytes **least-significant-byte first**!
            result |= UInt64(byte & 0b1111111) << (idx * 7)
        }
        return result
    }
    
    
    @inlinable
    public func decodeVarInt<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let u64Value = try decodeUInt64VarInt()
        return type.init(truncatingIfNeeded: u64Value)
    }
    
    @inlinable
    public func readRawBytes(length: Int, byteTransferStrategy: ByteBuffer.ByteTransferStrategy = .automatic) throws -> Data {
        guard let data = _buffer.readData(length: length, byteTransferStrategy: byteTransferStrategy) else {
            throw BinaryDecodingError.other("Unable to read raw bytes")
        }
        return data
    }
}
