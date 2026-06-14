//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2025 Stanford University
//
// SPDX-License-Identifier: MIT
//

// swiftlint:disable file_types_order

import SensorKit
import SpeziSensorKit
import SwiftUI


// MARK: Property Wrapper

/// Enables auto-updating access to SensorKit sensor access permissions within SwiftUI views.
@propertyWrapper
struct SensorAccessPermissions: DynamicProperty {
    @State private var authStatusObservers: [SRSensor: SensorAuthStatusObserver]
    
    var wrappedValue: Self {
        self
    }
    
    /// Creates an access permissions query observing all sensors.
    init() {
        self.init(sensors: SensorKit.allKnownSensors)
    }
    
    /// Creates an access permissions query observing a list of sensors.
    init(sensors: some Collection<any AnySensor>) {
        _authStatusObservers = .init(initialValue: sensors.reduce(into: [:]) { result, sensor in
            result[sensor.srSensor] = SensorAuthStatusObserver(sensor: sensor)
        })
        for (_, observer) in authStatusObservers {
            observer.startUpdates()
        }
    }
}


extension SensorAccessPermissions {
    /// Whether all of the sensors are in an undetermined state (i.e., the user has neither approved nor denied access).
    var isFullyUndetermined: Bool {
        authStatusObservers.values.allSatisfy { $0.authStatus == .notDetermined }
    }
    
    /// The number of authorized sensors.
    var numAuthorized: Int {
        authStatusObservers.values.count { $0.authStatus == .authorized }
    }
    
    /// The sensor's status.
    ///
    /// - Note: Use this instead of `sensor.authorizationStatus` to opt in to automatic observation tracking should the status change.
    subscript(sensor: any AnySensor) -> SRAuthorizationStatus {
        // we try to first go through the observers, in order to get observation tracking on the status
        // fallback path is only for those sensors that were not passed to the property wrapper init.
        authStatusObservers[sensor.srSensor]?.authStatus ?? sensor.authorizationStatus
    }
}


extension SensorAccessPermissions {
    @Observable
    fileprivate final class SensorAuthStatusObserver: NSObject, SRSensorReaderDelegate {
        @ObservationIgnored private let sensorReader: SRSensorReader
        private(set) var authStatus: SRAuthorizationStatus
        
        init(sensor: any AnySensor) {
            sensorReader = SRSensorReader(sensor: sensor.srSensor)
            authStatus = sensorReader.authorizationStatus
        }
        
        func startUpdates() {
            sensorReader.delegate = self
        }
    }
}


// MARK: AsyncStream

private final class SensorAuthStatusMonitor: NSObject, SRSensorReaderDelegate {
    var authStatusChangeHandler: ((SRAuthorizationStatus) -> Void)?
    
    func sensorReader(_ reader: SRSensorReader, didChange authorizationStatus: SRAuthorizationStatus) {
        authStatusChangeHandler?(authorizationStatus)
    }
}


extension AnySensor {
    var authStatusChanges: AsyncStream<SRAuthorizationStatus> {
        AsyncStream { continuation in
            nonisolated(unsafe) let reader = SRSensorReader(sensor: self.srSensor)
            nonisolated(unsafe) let monitor = SensorAuthStatusMonitor()
            monitor.authStatusChangeHandler = { newStatus in
                continuation.yield(newStatus)
            }
            continuation.onTermination = { _ in
                reader.delegate = nil
                monitor.authStatusChangeHandler = nil
            }
            reader.delegate = monitor
        }
    }
}
