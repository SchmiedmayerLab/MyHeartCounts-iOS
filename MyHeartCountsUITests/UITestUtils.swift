//
// This source file is part of the My Heart Counts iOS open-source project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFoundation
import XCTest


func sleep(for duration: Duration) {
    usleep(UInt32(duration.timeInterval * 1000000))
}


extension XCUIElement {
    enum Direction {
        case up, down, left, right // swiftlint:disable:this identifier_name
        
        var opposite: Self {
            switch self {
            case .up: .down
            case .down: .up
            case .left: .right
            case .right: .left
            }
        }
    }
    
    func swipe(_ direction: Direction, velocity: XCUIGestureVelocity = .default) {
        switch direction {
        case .up:
            swipeUp(velocity: velocity)
        case .down:
            swipeDown(velocity: velocity)
        case .left:
            swipeLeft(velocity: velocity)
        case .right:
            swipeRight(velocity: velocity)
        }
    }
}


extension XCUIElement {
    // This is required to work around an apparent XCTest bug when trying to tap e.g. the Health App's Profile button.
    // See also: https://stackoverflow.com/a/33534187
    func tryToTapReallySoftlyMaybeThisWillMakeItWork() {
        if isHittable {
            tap()
        } else {
            coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }
}


extension XCUIApplication {
    /// Expands a bottom sheet to cover the full height of the screen.
    func expandSheet(_ sheet: XCUIElement) {
        sheet.navigationBars.element
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: self.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
    }
}
