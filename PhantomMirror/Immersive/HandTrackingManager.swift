import Foundation
import ARKit
import RealityKit
import simd
import QuartzCore

@MainActor
@Observable
final class HandTrackingManager {
    private(set) var arSession = ARKitSession()
    private(set) var handTracking = HandTrackingProvider()
    private(set) var worldTracking = WorldTrackingProvider()

    private(set) var latestIntact: HandAnchor?
    private(set) var latestHead: DeviceAnchor?
    private(set) var isRunning = false
    private(set) var authorizationDenied = false

    private var updateTask: Task<Void, Never>?
    private var worldTask: Task<Void, Never>?

    var onIntactHandUpdate: ((HandAnchor, DeviceAnchor?) -> Void)?
    var onTrackingLost: (() -> Void)?

    func start() async {
        guard !isRunning else { return }

        guard HandTrackingProvider.isSupported else {
            authorizationDenied = true
            return
        }

        do {
            let auth = await arSession.requestAuthorization(for: [.handTracking, .worldSensing])
            if auth[.handTracking] == .denied {
                authorizationDenied = true
                return
            }

            var providers: [any DataProvider] = [handTracking]
            if WorldTrackingProvider.isSupported {
                providers.append(worldTracking)
            }
            try await arSession.run(providers)
            isRunning = true
            authorizationDenied = false
            listenForUpdates()
        } catch {
            authorizationDenied = true
            isRunning = false
        }
    }

    func stop() {
        updateTask?.cancel()
        worldTask?.cancel()
        updateTask = nil
        worldTask = nil
        // ARKitSession has no public stop(); cancelling consumers ends updates.
        arSession = ARKitSession()
        handTracking = HandTrackingProvider()
        worldTracking = WorldTrackingProvider()
        isRunning = false
        latestIntact = nil
        latestHead = nil
    }

    private func listenForUpdates() {
        updateTask = Task { [weak self] in
            guard let self else { return }
            for await update in self.handTracking.anchorUpdates {
                guard !Task.isCancelled else { break }
                await self.handleHandUpdate(update.anchor)
            }
        }

        worldTask = Task { [weak self] in
            guard let self else { return }
            // Poll predicted device pose for midline.
            while !Task.isCancelled {
                if let device = self.worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) {
                    self.latestHead = device
                }
                try? await Task.sleep(nanoseconds: 8_000_000) // ~120 Hz
            }
        }
    }

    private func handleHandUpdate(_ anchor: HandAnchor) async {
        // Caller decides which chirality is "intact" via filter outside.
        latestIntact = anchor
        if anchor.isTracked {
            onIntactHandUpdate?(anchor, latestHead)
        } else {
            onTrackingLost?()
        }
    }

    /// Returns the most recent head pose matrix, or identity fallback for simulator / cold start.
    func currentHeadPose() -> simd_float4x4 {
        if let head = latestHead, head.isTracked {
            return head.originFromAnchorTransform
        }
        // Fallback: identity (mirror across world YZ plane through origin).
        return matrix_identity_float4x4
    }
}
