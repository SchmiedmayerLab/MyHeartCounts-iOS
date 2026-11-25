//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable identifier_name

import SwiftUI

/// A giant panda drawn in code, which lumbers along on legs of its own.
struct DrawnGiantPanda {
    private static let fur = Color(red: 0.97, green: 0.96, blue: 0.92)
    private static let bamboo = Color(red: 0.42, green: 0.66, blue: 0.27)

    /// Black, or brown as on the rare Qinling pandas.
    let patches: Color
    /// Carries a sprig of bamboo in its mouth.
    let hasBamboo: Bool

    static func random() -> DrawnGiantPanda {
        DrawnGiantPanda(
            patches: Int.random(in: 0..<5) == 0
                ? Color(red: 0.42, green: 0.29, blue: 0.20)
                : Color(red: 0.11, green: 0.11, blue: 0.12),
            hasBamboo: Bool.random()
        )
    }

    /// Draws the giant panda around the origin, facing right, at `phase` of its stride.
    func draw(in context: GraphicsContext, phase: Double) {
        var context = context
        context.translateBy(x: 0, y: -abs(sin(phase)) * 5)
        context.rotate(by: .degrees(-cos(phase) * 4))

        let frontHip = CGPoint(x: 22, y: 10)
        let backHip = CGPoint(x: -23, y: 10)
        // The far legs trail the near ones a little, as in a gallop.
        let trailingPhase = phase - 0.7

        drawTail(in: context)
        drawLeg(in: context, hip: frontHip, swing: sin(trailingPhase), isFar: true)
        drawLeg(in: context, hip: backHip, swing: -sin(trailingPhase), isFar: true)
        drawBody(in: context)
        drawLeg(in: context, hip: frontHip, swing: sin(phase), isFar: false)
        drawLeg(in: context, hip: backHip, swing: -sin(phase), isFar: false)
        context.translateBy(x: 40, y: -17)
        drawHead(in: context)
    }

    private func drawTail(in context: GraphicsContext) {
        context.fill(Path(ellipseIn: CGRect(x: -45, y: -18, width: 14, height: 12)), with: .color(Self.fur))
    }

    /// `swing` goes from -1, reaching back, to 1, reaching forward.
    private func drawLeg(in context: GraphicsContext, hip: CGPoint, swing: Double, isFar: Bool) {
        var context = context
        context.translateBy(x: hip.x, y: hip.y)
        context.rotate(by: .degrees(-swing * 40))

        let leg = Path(roundedRect: CGRect(x: -7.5, y: -6, width: 15, height: 27), cornerRadius: 7.5)
        context.fill(leg, with: .color(patches))
        if isFar {
            context.fill(leg, with: .color(.white.opacity(0.12)))
        }
    }

    /// The white body, with the black band over the shoulders and the black haunches.
    private func drawBody(in context: GraphicsContext) {
        let body = Path(roundedRect: CGRect(x: -39, y: -23, width: 78, height: 44), cornerRadius: 22)
        context.fill(body, with: .color(Self.fur))

        var context = context
        context.clip(to: body)
        let black = GraphicsContext.Shading.color(patches)
        context.fill(Path(roundedRect: CGRect(x: 6, y: -27, width: 22, height: 52), cornerRadius: 11), with: black)
        context.fill(Path(ellipseIn: CGRect(x: -46, y: 4, width: 38, height: 30)), with: black)
    }

    /// Draws the head around the origin.
    private func drawHead(in context: GraphicsContext) {
        for x in [-17.0, 17] {
            context.fill(Path(ellipseIn: CGRect(x: x - 9, y: -27, width: 18, height: 17)), with: .color(patches))
        }

        let head = Path(ellipseIn: CGRect(x: -25, y: -22, width: 50, height: 44))
        context.fill(head, with: .color(Self.fur))

        for (x, tilt) in [(-10.0, 30.0), (10, -30)] {
            drawEye(in: context, center: CGPoint(x: x, y: -3), tilt: tilt)
        }

        var nose = Path()
        nose.move(to: CGPoint(x: -4, y: 6))
        nose.addLine(to: CGPoint(x: 4, y: 6))
        nose.addLine(to: CGPoint(x: 0, y: 10))
        nose.closeSubpath()
        context.fill(nose, with: .color(patches))
        context.stroke(nose, with: .color(patches), style: StrokeStyle(lineWidth: 2, lineJoin: .round))

        var mouth = Path()
        mouth.move(to: CGPoint(x: -5, y: 13))
        mouth.addQuadCurve(to: CGPoint(x: 0, y: 12), control: CGPoint(x: -2, y: 15))
        mouth.addQuadCurve(to: CGPoint(x: 5, y: 13), control: CGPoint(x: 2, y: 15))
        context.stroke(mouth, with: .color(patches), style: StrokeStyle(lineWidth: 1, lineCap: .round))

        if hasBamboo {
            drawBamboo(in: context)
        }
    }

    /// The drooping black patch around each eye. `tilt` turns the patch's top toward the nose.
    private func drawEye(in context: GraphicsContext, center: CGPoint, tilt: Double) {
        var context = context
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: .degrees(tilt))
        context.fill(Path(ellipseIn: CGRect(x: -6, y: -8.5, width: 12, height: 17)), with: .color(patches))
        context.rotate(by: .degrees(-tilt))
        context.fill(Path(ellipseIn: CGRect(x: -3, y: -4, width: 6, height: 6)), with: .color(.white.opacity(0.9)))
        context.fill(Path(ellipseIn: CGRect(x: -2.2, y: -3.2, width: 4.4, height: 4.4)), with: .color(.black))
        context.fill(Path(ellipseIn: CGRect(x: -0.6, y: -2.6, width: 1.8, height: 1.8)), with: .color(.white))
    }

    private func drawBamboo(in context: GraphicsContext) {
        var stalk = Path()
        stalk.move(to: CGPoint(x: -14, y: 15))
        stalk.addLine(to: CGPoint(x: 30, y: 9))
        context.stroke(stalk, with: .color(Self.bamboo), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))

        // The joints, where the stalk passes x = -6 and x = 12.
        var nodes = Path()
        for node in [CGPoint(x: -6, y: 14), CGPoint(x: 12, y: 11.5)] {
            nodes.move(to: CGPoint(x: node.x, y: node.y - 2.5))
            nodes.addLine(to: CGPoint(x: node.x, y: node.y + 2.5))
        }
        context.stroke(nodes, with: .color(Self.bamboo.opacity(0.6)), lineWidth: 1)

        for tilt in [-35.0, 10] {
            var leaf = context
            leaf.translateBy(x: 29, y: 9)
            leaf.rotate(by: .degrees(tilt))
            leaf.fill(Path(ellipseIn: CGRect(x: 0, y: -3, width: 16, height: 6)), with: .color(Self.bamboo))
        }
    }
}
