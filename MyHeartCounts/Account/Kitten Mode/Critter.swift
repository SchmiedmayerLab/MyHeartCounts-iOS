//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable force_unwrapping identifier_name trailing_comma void_function_in_ternary

import SwiftUI

/// One critter's run across the screen. Everything random is rolled up front, so that drawing
/// depends only on the time.
struct Critter: Identifiable {
    enum Look {
        case drawnKitten(DrawnKitten)
        case drawnRedPanda(DrawnRedPanda)
        case drawnPenguin(DrawnPenguin)
        /// The name of a photo in the asset catalog, cut out of its background and facing right.
        case photo(String)
    }

    /// Photos from Wikimedia Commons, all under CC0 or in the public domain. The comments name the
    /// original files.
    static let kittenPhotos = [
        "kitten-curious", // A curious kitten (Pixabay).jpg
        "kitten-cream", // A focused kitten (Pixabay).jpg
        "kitten-daisies", // A kitten on the lawn (Pixabay).jpg
        "kitten-tiny", // A seemingly innocent kitten (Pixabay).jpg
        "kitten-odd-eyes", // A white kitten (2016; cropped 2023).jpg
        "kitten-sitting", // Domestic tabby shorthair kitten.jpg
        "kitten-belly-up", // Orange Kitten on its Back.jpg
        "kitten-birman", // Sunday Kitty (Unsplash) (2017; cropped 2024).jpg
    ]
    static let redPandaPhotos = [
        "red-panda-sitting", // Red Panda (24774549282).jpg
        "red-panda-walking", // Red Panda (25193861686).jpg
        "red-panda-bamboo", // Red Panda (30763188080).jpg
        "red-panda-tail", // Red Panda - 52301611571.jpg
        "red-panda-reaching", // Red Panda - 52301690518.jpg
    ]
    static let penguinPhotos = [
        "penguin-chicks", // Emperor penguin chicks at Sea World · DF-ST-90-04598.JPG
        "penguin-family", // At the penguin rodeo (12815950293).jpg
        "penguin-fluffy", // Falkland-Penguins 19 57 46 697000.jpeg
        "penguin-waving", // Kaiserpinguinjunges.jpg
        "penguin-gentoo", // Penguin on a rock (Unsplash).jpg
        "penguin-shy", // Lonely Penguin (Unsplash).jpg
        "penguin-looking-up", // Gentoo Penguin. (9) (8670581675).jpg
    ]

    let id = UUID()
    let start = Date.now
    let look: Look
    /// Relative to the critter's usual length of about 130 points.
    let scale: Double
    /// How far down the screen it runs, from 0 to 1.
    let track: Double
    let runsRight: Bool
    /// Seconds from one side of the screen to the other.
    let duration: TimeInterval
    /// Strides per second.
    let cadence: Double

    static func random() -> Critter {
        Critter(
            look: randomLook(),
            scale: .random(in: 0.7...1.3),
            track: .random(in: 0.15...0.85),
            runsRight: .random(),
            duration: .random(in: 3...5),
            cadence: .random(in: 3...4.5)
        )
    }

    /// Half of the critters are kittens, and half of each kind are photos.
    private static func randomLook() -> Look {
        switch Int.random(in: 0..<4) {
        case 0: Bool.random() ? .drawnRedPanda(.random()) : .photo(redPandaPhotos.randomElement()!)
        case 1: Bool.random() ? .drawnPenguin(.random()) : .photo(penguinPhotos.randomElement()!)
        default: Bool.random() ? .drawnKitten(.random()) : .photo(kittenPhotos.randomElement()!)
        }
    }

    func draw(in context: GraphicsContext, size: CGSize, at date: Date) {
        let elapsed = date.timeIntervalSince(start)
        let margin = 90 * scale
        let x = (size.width + 2 * margin) * elapsed / duration - margin
        let phase = elapsed * cadence * 2 * .pi

        var context = context
        context.translateBy(x: runsRight ? x : size.width - x, y: size.height * track)
        context.scaleBy(x: runsRight ? scale : -scale, y: scale)
        // Keeps pale critters visible on a pale background.
        context.addFilter(.shadow(color: .black.opacity(0.4), radius: 3, y: 2))
        context.drawLayer { layer in
            switch look {
            case .drawnKitten(let kitten):
                kitten.draw(in: layer, phase: phase)
            case .drawnRedPanda(let redPanda):
                redPanda.draw(in: layer, phase: phase)
            case .drawnPenguin(let penguin):
                penguin.draw(in: layer, phase: phase)
            case .photo(let name):
                drawPhoto(named: name, in: layer, phase: phase)
            }
        }
    }

    /// Draws the photo around the origin. A photo can't move its legs, so it hops along instead.
    private func drawPhoto(named name: String, in context: GraphicsContext, phase: Double) {
        var context = context
        context.translateBy(x: 0, y: -abs(sin(phase / 2)) * 24)
        context.rotate(by: .degrees(sin(phase / 2) * 8))

        let photo = context.resolve(Image(name))
        let fit = 130 / max(photo.size.width, photo.size.height)
        let size = CGSize(width: photo.size.width * fit, height: photo.size.height * fit)
        context.draw(photo, in: CGRect(origin: CGPoint(x: -size.width / 2, y: -size.height / 2), size: size))
    }
}
