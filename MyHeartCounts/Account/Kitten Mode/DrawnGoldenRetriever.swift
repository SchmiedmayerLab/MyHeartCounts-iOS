//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable force_unwrapping identifier_name trailing_comma

import SwiftUI

/// A golden retriever drawn in code, which gallops on legs of its own, tongue out and tail wagging.
struct DrawnGoldenRetriever {
    private static let cream = Color(red: 0.99, green: 0.93, blue: 0.80)
    private static let nose = Color(red: 0.13, green: 0.10, blue: 0.09)

    let fur: Color

    static func random() -> DrawnGoldenRetriever {
        DrawnGoldenRetriever(fur: [
            Color(red: 0.89, green: 0.68, blue: 0.36),
            Color(red: 0.94, green: 0.81, blue: 0.56),
            Color(red: 0.80, green: 0.52, blue: 0.24),
        ].randomElement()!)
    }

    /// Draws the golden retriever around the origin, facing right, at `phase` of its stride.
    func draw(in context: GraphicsContext, phase: Double) {
        var context = context
        context.translateBy(x: 0, y: -abs(sin(phase)) * 8)
        context.rotate(by: .degrees(-cos(phase) * 6))

        let frontHip = CGPoint(x: 22, y: 9)
        let backHip = CGPoint(x: -23, y: 9)
        // The far legs trail the near ones a little, as in a gallop.
        let trailingPhase = phase - 0.7

        drawTail(in: context, phase: phase)
        drawLeg(in: context, hip: frontHip, swing: sin(trailingPhase), isFar: true)
        drawLeg(in: context, hip: backHip, swing: -sin(trailingPhase), isFar: true)
        drawBody(in: context)
        drawLeg(in: context, hip: frontHip, swing: sin(phase), isFar: false)
        drawLeg(in: context, hip: backHip, swing: -sin(phase), isFar: false)
        context.translateBy(x: 40, y: -18)
        drawHead(in: context)
    }

    /// The feathered tail, which wags twice as fast as the legs stride.
    private func drawTail(in context: GraphicsContext, phase: Double) {
        var tail = Path()
        tail.move(to: CGPoint(x: -30, y: -10))
        tail.addQuadCurve(
            to: CGPoint(x: -64, y: -30 + 12 * sin(phase * 2)),
            control: CGPoint(x: -54, y: -6)
        )
        context.stroke(tail, with: .color(fur), style: StrokeStyle(lineWidth: 12, lineCap: .round))
        context.stroke(tail, with: .color(Self.cream.opacity(0.5)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
    }

    /// `swing` goes from -1, reaching back, to 1, reaching forward.
    private func drawLeg(in context: GraphicsContext, hip: CGPoint, swing: Double, isFar: Bool) {
        var context = context
        context.translateBy(x: hip.x, y: hip.y)
        context.rotate(by: .degrees(-swing * 48))

        let leg = Path(roundedRect: CGRect(x: -6, y: -6, width: 12, height: 31), cornerRadius: 6)
        context.fill(leg, with: .color(fur))
        if isFar {
            context.fill(leg, with: .color(.black.opacity(0.18)))
        }
    }

    /// The body, with the paler feathering of the chest.
    private func drawBody(in context: GraphicsContext) {
        let body = Path(roundedRect: CGRect(x: -38, y: -19, width: 76, height: 38), cornerRadius: 19)
        context.fill(body, with: .color(fur))

        var context = context
        context.clip(to: body)
        context.fill(Path(ellipseIn: CGRect(x: 16, y: -4, width: 32, height: 32)), with: .color(Self.cream.opacity(0.6)))
    }

    /// Draws the head around the origin.
    private func drawHead(in context: GraphicsContext) {
        let head = Path(ellipseIn: CGRect(x: -22, y: -20, width: 44, height: 40))
        context.fill(head, with: .color(fur))

        for x in [-8.0, 10] {
            context.fill(Path(ellipseIn: CGRect(x: x - 3.5, y: -9, width: 7, height: 8)), with: .color(Self.nose))
            context.fill(Path(ellipseIn: CGRect(x: x - 0.5, y: -8, width: 2.4, height: 2.4)), with: .color(.white))
        }

        context.fill(Path(ellipseIn: CGRect(x: -12, y: 0, width: 26, height: 19)), with: .color(Self.cream))

        let tongue = Path(roundedRect: CGRect(x: -3, y: 12, width: 9, height: 12), cornerRadius: 4.5)
        context.fill(tongue, with: .color(Color(red: 0.95, green: 0.45, blue: 0.52)))
        var crease = Path()
        crease.move(to: CGPoint(x: 1.5, y: 14))
        crease.addLine(to: CGPoint(x: 1.5, y: 20))
        context.stroke(crease, with: .color(Color(red: 0.80, green: 0.30, blue: 0.38)), lineWidth: 1)

        var mouth = Path()
        mouth.move(to: CGPoint(x: -7, y: 11))
        mouth.addQuadCurve(to: CGPoint(x: 1, y: 10), control: CGPoint(x: -3, y: 14))
        mouth.addQuadCurve(to: CGPoint(x: 9, y: 11), control: CGPoint(x: 5, y: 14))
        context.stroke(mouth, with: .color(Self.nose), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))

        context.fill(Path(ellipseIn: CGRect(x: -4, y: 2, width: 10, height: 7)), with: .color(Self.nose))

        drawEar(in: context, center: CGPoint(x: -21, y: -3), tilt: 18)
        drawEar(in: context, center: CGPoint(x: 21, y: -3), tilt: -18)
    }

    /// A floppy ear, hanging down the side of the head. `tilt` swings its tip away from the face.
    private func drawEar(in context: GraphicsContext, center: CGPoint, tilt: Double) {
        var context = context
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: .degrees(tilt))
        let ear = Path(ellipseIn: CGRect(x: -7.5, y: -13, width: 15, height: 27))
        context.fill(ear, with: .color(fur))
        context.fill(ear, with: .color(.black.opacity(0.12)))
    }
}
