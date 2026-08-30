//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Charts


struct EmptyChartContent: ChartContent {
    var body: some ChartContent { }
}


struct SomeChartContent<Body: ChartContent>: ChartContent { // donate to GroveHealthKit?
    private let content: @MainActor () -> Body
    
    var body: some ChartContent {
        content()
    }
    
    init(@ChartContentBuilder _ content: @escaping @MainActor () -> Body) {
        self.content = content
    }
}


extension ChartContent {
    @ChartContentBuilder
    func `if`<T>(_ value: T?, @ChartContentBuilder _ makeContent: (T, Self) -> some ChartContent) -> some ChartContent {
        if let value {
            makeContent(value, self)
        } else {
            self
        }
    }
}
