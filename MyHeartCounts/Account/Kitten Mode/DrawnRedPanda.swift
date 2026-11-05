//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable force_unwrapping identifier_name trailing_comma

import SwiftUI

/// A red panda drawn in code, which gallops on legs of its own.
struct DrawnRedPanda {
    private static let legs = Color(red: 0.16, green: 0.10, blue: 0.09)
    private static let mask = Color(red: 0.98, green: 0.95, blue: 0.89)

    let fur: Color

    static func random() -> DrawnRedPanda {
        DrawnRedPanda(fur: [
            Color(red: 0.76, green: 0.31, blue: 0.13),
            Color(red: 0.70, green: 0.25, blue: 0.11),
            Color(red: 0.84, green: 0.39, blue: 0.16),
        ].randomElement()!)
    }

    /// Draws the red panda around the origin, facing right, at `phase` of its stride.
    func draw(in context: GraphicsContext, phase: Double) {
        var context = context
        context.translateBy(x: 0, y: -abs(sin(phase)) * 7)
        context.rotate(by: .degrees(-cos(phase) * 6))

        let frontHip = CGPoint(x: 21, y: 9)
        let backHip = CGPoint(x: -22, y: 9)
        // The far legs trail the near ones a little, as in a gallop.
        let trailingPhase = phase - 0.7

        drawTail(in: context, phase: phase)
        drawLeg(in: context, hip: frontHip, swing: sin(trailingPhase), isFar: true)
        drawLeg(in: context, hip: backHip, swing: -sin(trailingPhase), isFar: true)
        drawBody(in: context)
        drawLeg(in: context, hip: frontHip, swing: sin(phase), isFar: false)
        drawLeg(in: context, hip: backHip, swing: -sin(phase), isFar: false)
        context.translateBy(x: 38, y: -15)
        drawHead(in: context)
    }

    private func drawTail(in context: GraphicsContext, phase: Double) {
        var tail = Path()
        tail.move(to: CGPoint(x: -26, y: -4))
        tail.addQuadCurve(
            to: CGPoint(x: -72, y: -18 + 9 * sin(phase / 2)),
            control: CGPoint(x: -56, y: 4)
        )
        context.stroke(tail, with: .color(fur), style: StrokeStyle(lineWidth: 18, lineCap: .round))
        // The first ring starts clear of the body.
        let rings = StrokeStyle(lineWidth: 18, dash: [6, 8], dashPhase: -12)
        context.stroke(tail, with: .color(Self.mask.opacity(0.75)), style: rings)
    }

    /// `swing` goes from -1, reaching back, to 1, reaching forward.
    private func drawLeg(in context: GraphicsContext, hip: CGPoint, swing: Double, isFar: Bool) {
        var context = context
        context.translateBy(x: hip.x, y: hip.y)
        context.rotate(by: .degrees(-swing * 46))

        let leg = Path(roundedRect: CGRect(x: -6.5, y: -6, width: 13, height: 28), cornerRadius: 6.5)
        context.fill(leg, with: .color(Self.legs))
        if isFar {
            context.fill(leg, with: .color(.white.opacity(0.12)))
        }
    }

    private func drawBody(in context: GraphicsContext) {
        let body = Path(roundedRect: CGRect(x: -36, y: -20, width: 72, height: 39), cornerRadius: 19)
        context.fill(body, with: .color(fur))

        var context = context
        context.clip(to: body)
        context.fill(Path(ellipseIn: CGRect(x: -44, y: 7, width: 92, height: 30)), with: .color(Self.legs))
    }

    /// Draws the head around the origin.
    private func drawHead(in context: GraphicsContext) {
        drawEar(in: context, center: CGPoint(x: -17, y: -19), tilt: -22)
        drawEar(in: context, center: CGPoint(x: 18, y: -19), tilt: 22)

        let head = Path(ellipseIn: CGRect(x: -25, y: -22, width: 51, height: 43))
        context.fill(head, with: .color(fur))
        drawMask(in: context, head: head)

        for x in [-9.0, 11] {
            context.fill(Path(ellipseIn: CGRect(x: x - 4, y: -7, width: 8, height: 9)), with: .color(.black))
            context.fill(Path(ellipseIn: CGRect(x: x - 0.5, y: -6, width: 2.8, height: 2.8)), with: .color(.white))
        }

        var nose = Path()
        nose.move(to: CGPoint(x: -3, y: 5))
        nose.addLine(to: CGPoint(x: 5, y: 5))
        nose.addLine(to: CGPoint(x: 1, y: 9))
        nose.closeSubpath()
        context.fill(nose, with: .color(.black))
        context.stroke(nose, with: .color(.black), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))

        var mouth = Path()
        mouth.move(to: CGPoint(x: -4, y: 12))
        mouth.addQuadCurve(to: CGPoint(x: 1, y: 11), control: CGPoint(x: -1, y: 14))
        mouth.addQuadCurve(to: CGPoint(x: 6, y: 12), control: CGPoint(x: 3, y: 14))
        context.stroke(mouth, with: .color(Self.legs), style: StrokeStyle(lineWidth: 1, lineCap: .round))
    }

    private func drawEar(in context: GraphicsContext, center: CGPoint, tilt: Double) {
        var context = context
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: .degrees(tilt))
        context.fill(Path(ellipseIn: CGRect(x: -11, y: -13, width: 22, height: 26)), with: .color(Self.mask))
        context.fill(Path(ellipseIn: CGRect(x: -6.5, y: -6, width: 13, height: 17)), with: .color(Self.legs))
    }

    /// The white cheeks, muzzle and eyebrows, with a russet tear stripe below each eye.
    private func drawMask(in context: GraphicsContext, head: Path) {
        var context = context
        context.clip(to: head)
        let white = GraphicsContext.Shading.color(Self.mask)
        context.fill(Path(ellipseIn: CGRect(x: -30, y: -3, width: 20, height: 20)), with: white)
        context.fill(Path(ellipseIn: CGRect(x: 12, y: -3, width: 20, height: 20)), with: white)
        context.fill(Path(ellipseIn: CGRect(x: -13, y: 0, width: 28, height: 23)), with: white)
        context.fill(Path(ellipseIn: CGRect(x: -15, y: -16, width: 11, height: 7)), with: white)
        context.fill(Path(ellipseIn: CGRect(x: 6, y: -16, width: 11, height: 7)), with: white)

        var stripes = Path()
        stripes.move(to: CGPoint(x: -10, y: 1))
        stripes.addQuadCurve(to: CGPoint(x: -12, y: 16), control: CGPoint(x: -14, y: 8))
        stripes.move(to: CGPoint(x: 12, y: 1))
        stripes.addQuadCurve(to: CGPoint(x: 14, y: 16), control: CGPoint(x: 16, y: 8))
        context.stroke(stripes, with: .color(fur), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
    }
}
