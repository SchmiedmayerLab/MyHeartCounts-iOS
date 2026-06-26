//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import MyHeartCountsShared
import SwiftUI


/// Live-updating view that displays the app's current memory usage. Intended for debugging purposes only.
struct MemoryUsageIndicator: View {
    enum Style {
        case labeledContent
        case toolbarItem
    }
    
    private let style: Style
    private let updateInterval: Duration
    @State private var dataSource = DataSource()
    
    var body: some View {
        content
            .task {
                await dataSource.startUpdating(interval: updateInterval)
            }
    }
    
    @ViewBuilder private var content: some View {
        switch style {
        case .labeledContent:
            LabeledContent(
                "Memory Usage" as String,
                value: dataSource.memoryUsageString(short: false)
            )
        case .toolbarItem:
            VStack {
                Text(verbatim: "Memory")
                Text(verbatim: dataSource.memoryUsageString(short: true))
                    .font(.caption2)
            }
            .padding(.horizontal)
        }
    }
    
    init(style: Style, updateInterval: Duration = .seconds(1)) {
        self.style = style
        self.updateInterval = updateInterval
    }
}


extension MemoryUsageIndicator {
    @Observable
    @MainActor
    fileprivate final class DataSource {
        let physicalMemory: UInt64
        private(set) var residentMemory: UInt64 = 0
        private(set) var memoryFootprint: UInt64 = 0
        private let fmt = ByteCountFormatter()
        
        init() {
            physicalMemory = ProcessInfo.processInfo.physicalMemory
            fmt.countStyle = .memory
        }
        
        func startUpdating(interval: Duration) async {
            while !Task.isCancelled {
                self.residentMemory = ProcessInfo.residentMemory
                self.memoryFootprint = ProcessInfo.memoryFootprint
                try? await Task.sleep(for: interval)
            }
        }
        
        func memoryUsageString(short: Bool) -> String {
            let physical = fmt.string(fromByteCount: Int64(physicalMemory))
            let resident = fmt.string(fromByteCount: Int64(residentMemory) * 1024 * 1024)
            let footprint = fmt.string(fromByteCount: Int64(memoryFootprint) * 1024 * 1024)
            let text = "\(physical) / \(resident) / \(footprint)"
            if short {
                return text.replacingOccurrences(of: "B", with: "").replacingOccurrences(of: " ", with: "")
            } else {
                return text
            }
        }
    }
}
