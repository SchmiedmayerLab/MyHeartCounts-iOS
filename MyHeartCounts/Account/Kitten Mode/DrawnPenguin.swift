//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable identifier_name type_contents_order

import SwiftUI

/// A penguin drawn in code, which waddles on feet of its own.
struct DrawnPenguin {
    private static let back = Color(red: 0.13, green: 0.15, blue: 0.20)
    private static let belly = Color(red: 0.98, green: 0.97, blue: 0.94)
    private static let beak = Color(red: 0.96, green: 0.58, blue: 0.16)

    /// A grey, fluffy chick rather than a grown-up.
    let isChick: Bool

    static func random() -> DrawnPenguin {
        DrawnPenguin(isChick: Int.random(in: 0..<3) == 0)
    }

    private var plumage: Color {
        isChick ? Color(red: 0.55, green: 0.58, blue: 0.62) : Self.back
    }

    /// Draws the penguin around the origin, facing right, at `phase` of its stride.
    func draw(in context: GraphicsContext, phase: Double) {
        var context = context
        context.translateBy(x: 0, y: -abs(sin(phase)) * 5)
        // Rocking from foot to foot is what makes it a waddle.
        context.rotate(by: .degrees(sin(phase) * 11))

        drawFoot(in: context, x: 2, swing: sin(phase - 0.4), isFar: true)
        drawFlipper(in: context, x: 22, tilt: 58, phase: phase + .pi, isFar: true)
        drawBody(in: context)
        drawFoot(in: context, x: -6, swing: -sin(phase), isFar: false)
        drawHead(in: context)
        drawFlipper(in: context, x: -6, tilt: 24, phase: phase, isFar: false)
    }

    /// `swing` goes from -1, reaching back, to 1, reaching forward.
    private func drawFoot(in context: GraphicsContext, x: Double, swing: Double, isFar: Bool) {
        var context = context
        context.translateBy(x: x + swing * 9, y: 46 - max(0, swing) * 4)
        context.rotate(by: .degrees(-swing * 16))

        let foot = Path(roundedRect: CGRect(x: -7, y: -4, width: 25, height: 10), cornerRadius: 5)
        context.fill(foot, with: .color(Self.beak))
        if isFar {
            context.fill(foot, with: .color(.black.opacity(0.18)))
        }
    }

    /// `tilt` is how far forward of straight down the flipper is held, for balance.
    private func drawFlipper(in context: GraphicsContext, x: Double, tilt: Double, phase: Double, isFar: Bool) {
        var context = context
        context.translateBy(x: x, y: -8)
        context.rotate(by: .degrees(-tilt - sin(phase) * 22))

        var flipper = Path()
        flipper.move(to: CGPoint(x: -6, y: -3))
        flipper.addQuadCurve(to: CGPoint(x: -8, y: 38), control: CGPoint(x: -15, y: 20))
        flipper.addQuadCurve(to: CGPoint(x: 6, y: -3), control: CGPoint(x: 9, y: 18))
        flipper.closeSubpath()
        context.fill(flipper, with: .color(plumage))
        if isFar {
            context.fill(flipper, with: .color(.white.opacity(0.12)))
        }
    }

    private func drawBody(in context: GraphicsContext) {
        let body = Path(ellipseIn: CGRect(x: -35, y: -36, width: 70, height: 86))
        context.fill(body, with: .color(plumage))

        var context = context
        context.clip(to: body)
        let belly = isChick ? Color(red: 0.86, green: 0.87, blue: 0.87) : Self.belly
        context.fill(Path(ellipseIn: CGRect(x: -10, y: -22, width: 56, height: 74)), with: .color(belly))
    }

    private func drawHead(in context: GraphicsContext) {
        var context = context
        context.translateBy(x: 6, y: -40)

        if isChick {
            drawTuft(in: context)
        }
        let head = Path(ellipseIn: CGRect(x: -29, y: -27, width: 58, height: 54))
        context.fill(head, with: .color(plumage))
        drawFace(in: context, head: head)

        for x in [-1.0, 20] {
            context.fill(Path(ellipseIn: CGRect(x: x - 4.5, y: -8, width: 9, height: 10)), with: .color(.black))
            context.fill(Path(ellipseIn: CGRect(x: x - 0.5, y: -7, width: 3.2, height: 3.2)), with: .color(.white))
        }
        for x in [-9.0, 26] {
            context.fill(
                Path(ellipseIn: CGRect(x: x - 5, y: 3, width: 10, height: 6)),
                with: .color(Color(red: 0.98, green: 0.62, blue: 0.62).opacity(0.7))
            )
        }

        var beak = Path()
        beak.move(to: CGPoint(x: 3, y: 3))
        beak.addQuadCurve(to: CGPoint(x: 18, y: 3), control: CGPoint(x: 10, y: 0))
        beak.addQuadCurve(to: CGPoint(x: 10, y: 13), control: CGPoint(x: 17, y: 10))
        beak.addQuadCurve(to: CGPoint(x: 3, y: 3), control: CGPoint(x: 4, y: 10))
        beak.closeSubpath()
        context.fill(beak, with: .color(Self.beak))
    }

    private func drawTuft(in context: GraphicsContext) {
        var tuft = Path()
        for (x, tip) in [(-7.0, -13.0), (0, -3), (7, 7)] {
            tuft.move(to: CGPoint(x: x, y: -22))
            tuft.addQuadCurve(to: CGPoint(x: tip, y: -36), control: CGPoint(x: x, y: -31))
        }
        context.stroke(tuft, with: .color(plumage), style: StrokeStyle(lineWidth: 4, lineCap: .round))
    }

    /// The white, heart-shaped face.
    private func drawFace(in context: GraphicsContext, head: Path) {
        var context = context
        context.clip(to: head)
        let white = GraphicsContext.Shading.color(Self.belly)
        context.fill(Path(ellipseIn: CGRect(x: -15, y: -15, width: 28, height: 34)), with: white)
        context.fill(Path(ellipseIn: CGRect(x: 6, y: -15, width: 28, height: 34)), with: white)
        context.fill(Path(ellipseIn: CGRect(x: -12, y: 2, width: 42, height: 30)), with: white)
    }
}
