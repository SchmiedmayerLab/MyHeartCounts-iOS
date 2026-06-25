//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// periphery:ignore:all - API
// swiftlint:disable missing_docs

import Foundation
public import NIOCore


extension BinaryEncoder {
    @inlinable
    public static func encode(_ value: some BinaryEncodable) throws -> ByteBuffer {
        var buffer = ByteBuffer()
        try Self.encode(value, into: &buffer)
        return buffer
    }
    
    @inlinable
    public static func encode(_ value: some BinaryEncodable, into dstBuffer: inout ByteBuffer) throws {
        let encoder = BinaryEncoder()
        try value.binaryEncode(to: encoder)
        dstBuffer.writeImmutableBuffer(encoder._buffer)
    }
}


public final class BinaryEncoder {
    @usableFromInline var _buffer: ByteBuffer // swiftlint:disable:this identifier_name
    
    @inlinable
    init(buffer: ByteBuffer = ByteBuffer()) {
        self._buffer = buffer
    }
    
    /// Prepares the encoder's underlying buffer so that it can hold at least `writableBytes` additional bytes
    @inlinable
    public func reserveCapacity(writableBytes: Int) {
        _buffer.reserveCapacity(minimumWritableBytes: writableBytes)
    }
    
    @inlinable
    public func encodeFullWidthInt<T: FixedWidthInteger>(_ value: T) {
        _buffer.writeInteger(value, endianness: .big)
    }
    
    /// Writes a VarInt value to the buffer, without using the ZigZag encoding!
    /// - returns: the number of bytes written to the buffer
    @discardableResult
    public func encodeVarInt<T: FixedWidthInteger>(_ value: T) -> Int {
        var writtenBytes = 0
        var u64Val = UInt64(truncatingIfNeeded: value)
        while u64Val > 127 {
            _buffer.writeInteger(UInt8(u64Val & 0x7f | 0x80))
            u64Val >>= 7
            writtenBytes += 1
        }
        _buffer.writeInteger(UInt8(u64Val))
        return writtenBytes + 1
    }
    
    
    @inlinable
    public func encode(_ value: some BinaryEncodable) throws {
        try value.binaryEncode(to: self)
    }
    
    
    @inlinable
    public func encodeLengthPrefixed(_ collection: some Collection<some BinaryEncodable>) throws {
        try collection.count.binaryEncode(to: self)
        for element in collection {
            try element.binaryEncode(to: self)
        }
    }
    
    
    @inlinable
    public func writeRawBytes(_ bytes: some Sequence<UInt8>) {
        _buffer.writeBytes(bytes)
    }
    
    @inlinable
    public func writeRawBytes(minimumWritableBytes: Int, _ block: (UnsafeMutableRawBufferPointer) -> Int) {
        self._buffer.writeWithUnsafeMutableBytes(minimumWritableBytes: minimumWritableBytes, block)
    }
}
