//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order

import SwiftUI

/// The secret kitten mode: every `releaseCritter(in:)` sends a random kitten, red panda or penguin
/// across the screen.
///
/// The critters run in a window of their own, because the sheet they're released from covers
/// everything in the app's window. Their window ignores touches, so the sheet stays usable.
@MainActor
final class KittenMode {
    fileprivate private(set) var critters: [Critter] = []
    private var window: UIWindow?

    func releaseCritter(in scene: UIWindowScene) {
        let critter = Critter.random()
        critters.append(critter)
        if window == nil {
            window = makeWindow(in: scene)
        }
        Task {
            try? await Task.sleep(for: .seconds(critter.duration))
            critters.removeAll { $0.id == critter.id }
            if critters.isEmpty {
                window?.isHidden = true
                window = nil
            }
        }
    }

    private func makeWindow(in scene: UIWindowScene) -> UIWindow {
        let host = UIHostingController(rootView: CrittersView(mode: self))
        host.view.backgroundColor = .clear

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert
        window.isUserInteractionEnabled = false
        window.rootViewController = host
        window.isHidden = false
        return window
    }
}

private struct CrittersView: View {
    let mode: KittenMode

    var body: some View {
        TimelineView(.animation) { timeline in
            let critters = mode.critters
            Canvas { context, size in
                for critter in critters {
                    critter.draw(in: context, size: size, at: timeline.date)
                }
            }
        }
        .ignoresSafeArea()
    }
}
