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

    private(set) var latestHead: DeviceAnchor?
    private(set) var isRunning = false
    private(set) var authorizationDenied = false
    private(set) var lastErrorDescription: String?
    private(set) var averageUpdateIntervalMs: Double = 0

    /// Which chirality is the intact (tracked) hand. Set by the UI before/while running.
    var intactChirality: HandAnchor.Chirality = .left

    private var updateTask: Task<Void, Never>?
    private var worldTask: Task<Void, Never>?
    private var latestByChirality: [HandAnchor.Chirality: HandAnchor] = [:]
    private var lastIntactUpdateTime: CFTimeInterval?

    /// Fired only for the intact hand while tracked.
    var onIntactHandUpdate: ((HandAnchor, DeviceAnchor?) -> Void)?
    /// Fired only when the intact hand itself is lost (not when the missing side has no hand).
    var onIntactHandLost: (() -> Void)?

    func start() async {
        guard !isRunning else { return }

        guard HandTrackingProvider.isSupported else {
            authorizationDenied = true
            lastErrorDescription = "Hand tracking is unavailable (Vision Pro device required)"
            return
        }
        guard WorldTrackingProvider.isSupported else {
            authorizationDenied = true
            lastErrorDescription = "World tracking is unavailable, so the body midline cannot be located"
            return
        }

        do {
            let auth = await arSession.requestAuthorization(for: [.handTracking, .worldSensing])
            guard auth[.handTracking] == .allowed else {
                authorizationDenied = true
                lastErrorDescription = "Hand Tracking permission was not granted"
                return
            }
            guard auth[.worldSensing] == .allowed else {
                authorizationDenied = true
                lastErrorDescription = "World Sensing permission was not granted"
                return
            }

            try await arSession.run([handTracking, worldTracking])
            isRunning = true
            authorizationDenied = false
            lastErrorDescription = nil
            listenForUpdates()
        } catch {
            authorizationDenied = true
            isRunning = false
            lastErrorDescription = String(describing: error)
        }
    }

    func stop() {
        updateTask?.cancel()
        worldTask?.cancel()
        updateTask = nil
        worldTask = nil
        arSession = ARKitSession()
        handTracking = HandTrackingProvider()
        worldTracking = WorldTrackingProvider()
        isRunning = false
        latestByChirality.removeAll()
        latestHead = nil
        lastIntactUpdateTime = nil
        averageUpdateIntervalMs = 0
        onIntactHandUpdate = nil
        onIntactHandLost = nil
    }

    private func listenForUpdates() {
        updateTask = Task { [weak self] in
            guard let self else { return }
            for await update in self.handTracking.anchorUpdates {
                guard !Task.isCancelled else { break }
                self.handleHandUpdate(update.anchor)
            }
        }

        worldTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if let device = self.worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) {
                    self.latestHead = device
                }
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
        }
    }

    private func handleHandUpdate(_ anchor: HandAnchor) {
        latestByChirality[anchor.chirality] = anchor

        // Only the intact hand drives rendering / lost state.
        guard anchor.chirality == intactChirality else { return }

        if anchor.isTracked, anchor.handSkeleton != nil {
            let now = CACurrentMediaTime()
            if let previous = lastIntactUpdateTime {
                let sample = (now - previous) * 1_000
                averageUpdateIntervalMs = averageUpdateIntervalMs == 0
                    ? sample
                    : averageUpdateIntervalMs * 0.9 + sample * 0.1
            }
            lastIntactUpdateTime = now
            onIntactHandUpdate?(anchor, latestHead)
        } else {
            lastIntactUpdateTime = nil
            onIntactHandLost?()
        }
    }

    func currentHeadPose() -> simd_float4x4? {
        if let head = latestHead, head.isTracked {
            return head.originFromAnchorTransform
        }
        return nil
    }
}
