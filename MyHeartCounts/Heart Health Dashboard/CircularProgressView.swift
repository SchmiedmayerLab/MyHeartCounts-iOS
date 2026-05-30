//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order

import Foundation
import SwiftUI


/// A circular progress view.
///
/// Content placed inside the progress view (via ``init(_:lineWidth:content:)``) is automatically centered and constrained to the largest square that fits within the ring.
///
/// Use SwiftUI's `.tint(_:)` view modifier to set the color of the progress indicator.
struct CircularProgressView<Content: View>: View {
    private let value: Double
    private let lineWidth: Double
    private let content: Content
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(
                    .gray.tertiary,
                    lineWidth: lineWidth
                )
            Circle()
                .trim(from: 0, to: value)
                .stroke(
                    .tint,
                    style: StrokeStyle(
                        lineWidth: lineWidth,
                        lineCap: .round
                    )
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut, value: value)
            if !(content is EmptyView) {
                // Constrain the content to the inscribed square of the ring's interior (side = diameter / √2),
                // so it sits fully within the circle rather than under the stroke, then re-center it.
                GeometryReader { geometry in
                    let diameter = min(geometry.size.width, geometry.size.height)
                    let side = max(0, (diameter - lineWidth) / 2.squareRoot())
                    content
                        .frame(width: side, height: side)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(lineWidth / 2)
    }

    init(
        _ value: some BinaryFloatingPoint,
        lineWidth: Double = 5,
        @ViewBuilder content: () -> Content = { EmptyView() }
    ) {
        self.value = Double(value)
        self.lineWidth = lineWidth
        self.content = content()
    }
}


extension CircularProgressView where Content == CircularProgressPercentLabel {
    /// Creates a circular progress view that displays the progress as a percentage in its center.
    ///
    /// The label automatically scales down to fit within the circle.
    init(percent value: some BinaryFloatingPoint, lineWidth: Double = 5) {
        let value = Double(value)
        self.init(value, lineWidth: lineWidth) {
            CircularProgressPercentLabel(value: value)
        }
    }
}


/// The percentage label used by ``CircularProgressView/init(percent:lineWidth:)``.
struct CircularProgressPercentLabel: View {
    let value: Double

    var body: some View {
        Text(value, format: .percent.precision(.fractionLength(0)))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.1)
    }
}
