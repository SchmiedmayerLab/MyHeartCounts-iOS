//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable force_unwrapping identifier_name trailing_comma

import SwiftUI

/// A black panther drawn in code, which bounds along on legs of its own.
struct DrawnBlackPanther {
    private static let fur = Color(red: 0.11, green: 0.11, blue: 0.14)
    /// The faint rosettes that show through a black panther's coat in the right light.
    private static let rosettes = Color.white.opacity(0.05)

    let eyeColor: Color

    static func random() -> DrawnBlackPanther {
        DrawnBlackPanther(eyeColor: [
            Color(red: 0.93, green: 0.80, blue: 0.20),
            Color(red: 0.62, green: 0.84, blue: 0.25),
            Color(red: 0.95, green: 0.62, blue: 0.18),
        ].randomElement()!)
    }

    /// Draws the black panther around the origin, facing right, at `phase` of its stride.
    func draw(in context: GraphicsContext, phase: Double) {
        var context = context
        context.translateBy(x: 0, y: -abs(sin(phase)) * 9)
        context.rotate(by: .degrees(-cos(phase) * 7))

        let frontHip = CGPoint(x: 24, y: 7)
        let backHip = CGPoint(x: -26, y: 7)
        // The far legs trail the near ones a little, as in a gallop.
        let trailingPhase = phase - 0.7

        drawTail(in: context, phase: phase)
        drawLeg(in: context, hip: frontHip, swing: sin(trailingPhase), isFar: true)
        drawLeg(in: context, hip: backHip, swing: -sin(trailingPhase), isFar: true)
        drawBody(in: context)
        drawLeg(in: context, hip: frontHip, swing: sin(phase), isFar: false)
        drawLeg(in: context, hip: backHip, swing: -sin(phase), isFar: false)
        context.translateBy(x: 42, y: -14)
        drawHead(in: context)
    }

    /// The long tail, which hangs low and curls up at the tip.
    private func drawTail(in context: GraphicsContext, phase: Double) {
        var tail = Path()
        tail.move(to: CGPoint(x: -34, y: -6))
        tail.addCurve(
            to: CGPoint(x: -84, y: -16 + 8 * sin(phase / 2)),
            control1: CGPoint(x: -58, y: 2),
            control2: CGPoint(x: -76, y: 14)
        )
        context.stroke(tail, with: .color(Self.fur), style: StrokeStyle(lineWidth: 8, lineCap: .round))
    }

    /// `swing` goes from -1, reaching back, to 1, reaching forward.
    private func drawLeg(in context: GraphicsContext, hip: CGPoint, swing: Double, isFar: Bool) {
        var context = context
        context.translateBy(x: hip.x, y: hip.y)
        context.rotate(by: .degrees(-swing * 52))

        let leg = Path(roundedRect: CGRect(x: -6, y: -6, width: 12, height: 32), cornerRadius: 6)
        context.fill(leg, with: .color(Self.fur))
        if isFar {
            context.fill(leg, with: .color(.white.opacity(0.1)))
        }
    }

    /// The long, low body, with a sheen along the back and faint rosettes on the flank.
    private func drawBody(in context: GraphicsContext) {
        let body = Path(roundedRect: CGRect(x: -40, y: -17, width: 80, height: 34), cornerRadius: 17)
        context.fill(body, with: .color(Self.fur))

        var context = context
        context.clip(to: body)
        context.fill(Path(ellipseIn: CGRect(x: -32, y: -17, width: 60, height: 12)), with: .color(.white.opacity(0.08)))
        var rosettes = Path()
        for center in [CGPoint(x: -24, y: 2), CGPoint(x: -10, y: -4), CGPoint(x: -14, y: 9), CGPoint(x: 2, y: 4), CGPoint(x: 14, y: -3)] {
            rosettes.addEllipse(in: CGRect(x: center.x - 4, y: center.y - 3.5, width: 8, height: 7))
        }
        context.stroke(rosettes, with: .color(Self.rosettes), lineWidth: 1.5)
    }

    /// Draws the head around the origin.
    private func drawHead(in context: GraphicsContext) {
        for x in [-13.0, 13] {
            context.fill(Path(ellipseIn: CGRect(x: x - 7, y: -22, width: 14, height: 13)), with: .color(Self.fur))
            context.fill(Path(ellipseIn: CGRect(x: x - 3.5, y: -18.5, width: 7, height: 6)), with: .color(.white.opacity(0.12)))
        }

        let head = Path(ellipseIn: CGRect(x: -20, y: -17, width: 40, height: 34))
        context.fill(head, with: .color(Self.fur))
        context.fill(Path(ellipseIn: CGRect(x: -9, y: 1, width: 20, height: 14)), with: .color(.white.opacity(0.06)))

        for x in [-7.0, 9] {
            drawEye(in: context, center: CGPoint(x: x, y: -5))
        }

        var nose = Path()
        nose.move(to: CGPoint(x: -2.5, y: 4))
        nose.addLine(to: CGPoint(x: 4.5, y: 4))
        nose.addLine(to: CGPoint(x: 1, y: 7.5))
        nose.closeSubpath()
        context.fill(nose, with: .color(Color(red: 0.32, green: 0.28, blue: 0.30)))

        var whiskers = Path()
        for (from, to) in [(-8.0, -26.0), (10, 28)] {
            whiskers.move(to: CGPoint(x: from, y: 7))
            whiskers.addLine(to: CGPoint(x: to, y: 4))
            whiskers.move(to: CGPoint(x: from, y: 9))
            whiskers.addLine(to: CGPoint(x: to, y: 12))
        }
        context.stroke(whiskers, with: .color(.white.opacity(0.55)), lineWidth: 0.7)
    }

    /// An almond-shaped eye with a slit pupil.
    private func drawEye(in context: GraphicsContext, center: CGPoint) {
        var eye = Path()
        eye.move(to: CGPoint(x: center.x - 5, y: center.y))
        eye.addQuadCurve(to: CGPoint(x: center.x + 5, y: center.y), control: CGPoint(x: center.x, y: center.y - 6))
        eye.addQuadCurve(to: CGPoint(x: center.x - 5, y: center.y), control: CGPoint(x: center.x, y: center.y + 6))
        context.fill(eye, with: .color(eyeColor))
        context.fill(Path(ellipseIn: CGRect(x: center.x - 1.2, y: center.y - 3, width: 2.4, height: 6)), with: .color(.black))
        context.fill(Path(ellipseIn: CGRect(x: center.x + 1, y: center.y - 2.2, width: 1.6, height: 1.6)), with: .color(.white))
    }
}
