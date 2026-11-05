//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable force_unwrapping identifier_name trailing_comma type_contents_order

import SwiftUI

/// A kitten drawn in code, which gallops on legs of its own.
struct DrawnKitten {
    struct Coat {
        var fur: Color
        /// Darker ears, face, legs and tail, as on a Siamese.
        var points: Color?
        var stripes: Color?
        /// A patch on the back and head, and a smaller one on the flank, as on a calico.
        var patches: (Color, Color)?
        /// White chest, muzzle and paws, as on a tuxedo cat.
        var hasBib = false

        static let all = [
            Coat(fur: Color(red: 0.96, green: 0.65, blue: 0.30), stripes: Color(red: 0.84, green: 0.45, blue: 0.14)),
            Coat(fur: Color(red: 0.64, green: 0.54, blue: 0.44), stripes: Color(red: 0.32, green: 0.25, blue: 0.20)),
            Coat(fur: Color(red: 0.60, green: 0.63, blue: 0.68)),
            Coat(fur: Color(red: 0.17, green: 0.17, blue: 0.19)),
            Coat(fur: Color(red: 0.98, green: 0.97, blue: 0.95)),
            Coat(fur: Color(red: 0.17, green: 0.17, blue: 0.19), hasBib: true),
            Coat(
                fur: Color(red: 0.98, green: 0.97, blue: 0.95),
                patches: (Color(red: 0.93, green: 0.56, blue: 0.20), Color(red: 0.20, green: 0.18, blue: 0.18))
            ),
            Coat(fur: Color(red: 0.95, green: 0.89, blue: 0.78), points: Color(red: 0.34, green: 0.25, blue: 0.21)),
        ]
    }

    let coat: Coat
    let eyeColor: Color

    static func random() -> DrawnKitten {
        DrawnKitten(
            coat: Coat.all.randomElement()!,
            eyeColor: [.green, .blue, .yellow, .orange].randomElement()!
        )
    }

    /// Draws the kitten around the origin, facing right, at `phase` of its stride.
    func draw(in context: GraphicsContext, phase: Double) {
        var context = context
        context.translateBy(x: 0, y: -abs(sin(phase)) * 8)
        context.rotate(by: .degrees(-cos(phase) * 7))

        let frontHip = CGPoint(x: 20, y: 8)
        let backHip = CGPoint(x: -21, y: 8)
        // The far legs trail the near ones a little, as in a gallop.
        let trailingPhase = phase - 0.7

        drawTail(in: context, phase: phase)
        drawLeg(in: context, hip: frontHip, swing: sin(trailingPhase), isFar: true)
        drawLeg(in: context, hip: backHip, swing: -sin(trailingPhase), isFar: true)
        drawBody(in: context)
        drawLeg(in: context, hip: frontHip, swing: sin(phase), isFar: false)
        drawLeg(in: context, hip: backHip, swing: -sin(phase), isFar: false)
        context.translateBy(x: 36, y: -16)
        drawHead(in: context)
    }

    private func drawTail(in context: GraphicsContext, phase: Double) {
        var tail = Path()
        tail.move(to: CGPoint(x: -26, y: -6))
        tail.addQuadCurve(
            to: CGPoint(x: -60, y: -32 + 10 * sin(phase / 2)),
            control: CGPoint(x: -54, y: -4)
        )
        context.stroke(tail, with: .color(coat.points ?? coat.fur), style: StrokeStyle(lineWidth: 9, lineCap: .round))
        if let stripes = coat.stripes {
            context.stroke(tail, with: .color(stripes), style: StrokeStyle(lineWidth: 9, dash: [4, 7]))
        }
    }

    /// `swing` goes from -1, reaching back, to 1, reaching forward.
    private func drawLeg(in context: GraphicsContext, hip: CGPoint, swing: Double, isFar: Bool) {
        var context = context
        context.translateBy(x: hip.x, y: hip.y)
        context.rotate(by: .degrees(-swing * 50))

        let leg = Path(roundedRect: CGRect(x: -5.5, y: -6, width: 11, height: 30), cornerRadius: 5.5)
        context.fill(leg, with: .color(coat.points ?? coat.fur))
        if coat.hasBib {
            let paw = Path(roundedRect: CGRect(x: -5.5, y: 14, width: 11, height: 10), cornerRadius: 5)
            context.fill(paw, with: .color(.white))
        }
        if isFar {
            context.fill(leg, with: .color(.black.opacity(0.2)))
        }
    }

    private func drawBody(in context: GraphicsContext) {
        let body = Path(roundedRect: CGRect(x: -34, y: -18, width: 68, height: 36), cornerRadius: 18)
        context.fill(body, with: .color(coat.fur))

        var context = context
        context.clip(to: body)
        if let stripes = coat.stripes {
            for x in [-24.0, -12, 0, 12] {
                var stripe = Path()
                stripe.move(to: CGPoint(x: x, y: -20))
                stripe.addLine(to: CGPoint(x: x - 3, y: 2))
                context.stroke(stripe, with: .color(stripes), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }
        }
        if let patches = coat.patches {
            context.fill(Path(ellipseIn: CGRect(x: -36, y: -26, width: 40, height: 32)), with: .color(patches.0))
            context.fill(Path(ellipseIn: CGRect(x: -12, y: -2, width: 20, height: 16)), with: .color(patches.1))
        }
        if coat.hasBib {
            context.fill(Path(ellipseIn: CGRect(x: 23, y: -10, width: 30, height: 34)), with: .color(.white))
        }
    }

    /// Draws the head around the origin.
    private func drawHead(in context: GraphicsContext) {
        drawEar(in: context, base: CGPoint(x: -19, y: -7), tip: CGPoint(x: -17, y: -31), end: CGPoint(x: -3, y: -17))
        drawEar(in: context, base: CGPoint(x: 5, y: -17), tip: CGPoint(x: 19, y: -31), end: CGPoint(x: 21, y: -7))

        let head = Path(ellipseIn: CGRect(x: -22, y: -19, width: 44, height: 38))
        context.fill(head, with: .color(coat.fur))
        drawFaceMarkings(in: context, head: head)

        for x in [-8.0, 10] {
            context.fill(Path(ellipseIn: CGRect(x: x - 4.5, y: -8, width: 9, height: 10)), with: .color(eyeColor))
            context.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: -7, width: 5, height: 8)), with: .color(.black))
            context.fill(Path(ellipseIn: CGRect(x: x - 0.5, y: -6.5, width: 2.4, height: 2.4)), with: .color(.white))
        }

        var nose = Path()
        nose.move(to: CGPoint(x: -2, y: 3))
        nose.addLine(to: CGPoint(x: 4, y: 3))
        nose.addLine(to: CGPoint(x: 1, y: 6))
        nose.closeSubpath()
        context.fill(nose, with: .color(.pink))

        var whiskers = Path()
        for (from, to) in [(-9.0, -27.0), (12, 29)] {
            whiskers.move(to: CGPoint(x: from, y: 6))
            whiskers.addLine(to: CGPoint(x: to, y: 3))
            whiskers.move(to: CGPoint(x: from, y: 8))
            whiskers.addLine(to: CGPoint(x: to, y: 11))
        }
        context.stroke(whiskers, with: .color(.gray), lineWidth: 0.7)
    }

    private func drawEar(in context: GraphicsContext, base: CGPoint, tip: CGPoint, end: CGPoint) {
        var ear = Path()
        ear.move(to: base)
        ear.addLine(to: tip)
        ear.addLine(to: end)
        ear.closeSubpath()
        context.fill(ear, with: .color(coat.points ?? coat.patches?.1 ?? coat.fur))

        let center = CGPoint(x: (base.x + tip.x + end.x) / 3, y: (base.y + tip.y + end.y) / 3)
        var context = context
        context.translateBy(x: center.x, y: center.y)
        context.scaleBy(x: 0.55, y: 0.55)
        context.translateBy(x: -center.x, y: -center.y)
        context.fill(ear, with: .color(.pink.opacity(0.7)))
    }

    private func drawFaceMarkings(in context: GraphicsContext, head: Path) {
        var context = context
        context.clip(to: head)
        if let points = coat.points {
            context.fill(Path(ellipseIn: CGRect(x: -15, y: -11, width: 32, height: 28)), with: .color(points))
        }
        if let stripes = coat.stripes {
            for x in [-5.0, 1, 7] {
                var stripe = Path()
                stripe.move(to: CGPoint(x: x, y: -20))
                stripe.addLine(to: CGPoint(x: x, y: -11))
                context.stroke(stripe, with: .color(stripes), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        }
        if let patches = coat.patches {
            context.fill(Path(ellipseIn: CGRect(x: -30, y: -24, width: 30, height: 30)), with: .color(patches.0))
        }
        if coat.hasBib {
            context.fill(Path(ellipseIn: CGRect(x: -11, y: 0, width: 24, height: 22)), with: .color(.white))
        }
    }
}
