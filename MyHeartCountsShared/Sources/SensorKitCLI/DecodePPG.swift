//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import ArgumentParser
import Foundation
import GroveFoundation
import MyHeartCountsShared


struct DecodePPG: ParsableCommand {
    private struct CommandError: Error {
        let message: String
        init(_ message: String) {
            self.message = message
        }
    }
    
    static let configuration = CommandConfiguration(
        commandName: "decode-ppg",
        abstract: "Decode binary PPG data files created by My Heart Counts"
    )
    
    @Argument(help: "The input file")
    var input: String
    
    @Argument(help: "The output file")
    var output: String? = nil
    
    func run() throws {
        let inputUrl = URL(filePath: input, relativeTo: .currentDirectory())
        let data = try Data(contentsOf: inputUrl)
        let samples = try BinaryDecoder.decode([PPGSample].self, from: consume data)
        let jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .iso8601
        jsonEncoder.outputFormatting = [.prettyPrinted]
        let samplesJSON = try jsonEncoder.encode(consume samples)
        if let outputUrl = output.map({ URL(filePath: $0, relativeTo: .currentDirectory()) }) {
            try samplesJSON.write(to: outputUrl)
        } else {
            print(String(decoding: consume samplesJSON, as: UTF8.self))
        }
    }
}
