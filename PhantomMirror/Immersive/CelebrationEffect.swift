import Foundation
import RealityKit
import UIKit
import QuartzCore

/// Lightweight confetti burst for task completion.
@MainActor
final class CelebrationEffect {
    let root = Entity()

    private struct Particle {
        var entity: ModelEntity
        var velocity: SIMD3<Float>
        var angularVelocity: SIMD3<Float>
        var birth: CFTimeInterval
    }

    private var particles: [Particle] = []
    private let lifetime: CFTimeInterval = 1.8
    private let gravity: Float = -2.4

    func burst(at position: SIMD3<Float>, now: CFTimeInterval, isGrand: Bool = false) {
        let colors: [UIColor] = [
            .systemPink, .systemYellow, .systemGreen, .systemCyan,
            .systemOrange, .systemPurple, .systemMint
        ]

        let count = isGrand ? 150 : 48
        let speedMultiplier: Float = isGrand ? 1.5 : 1.0
        let spread: Float = isGrand ? 0.08 : 0.04

        for i in 0..<count {
            let color = colors[i % colors.count]
            let size = Float.random(in: 0.006...0.014)
            let particle = ModelEntity(
                mesh: .generateBox(size: size, cornerRadius: size * 0.15),
                materials: [UnlitMaterial(color: color)]
            )
            particle.position = position + SIMD3(
                Float.random(in: -spread...spread),
                Float.random(in: -(spread/2)...(spread * 1.25)),
                Float.random(in: -spread...spread)
            )
            root.addChild(particle)

            let direction = SIMD3<Float>(
                Float.random(in: -1...1),
                Float.random(in: 0.2...1.8),
                Float.random(in: -1...1)
            )
            let speed = Float.random(in: 0.35...1.1) * speedMultiplier
            let normalized = simd_normalize(direction)
            particles.append(
                Particle(
                    entity: particle,
                    velocity: normalized * speed,
                    angularVelocity: SIMD3(
                        Float.random(in: -6...6),
                        Float.random(in: -6...6),
                        Float.random(in: -6...6)
                    ),
                    birth: now
                )
            )
        }
    }

    func update(now: CFTimeInterval, delta: Float) {
        guard !particles.isEmpty else { return }

        var next: [Particle] = []
        next.reserveCapacity(particles.count)

        for var particle in particles {
            let age = now - particle.birth
            if age >= lifetime {
                particle.entity.removeFromParent()
                continue
            }

            particle.velocity.y += gravity * delta
            particle.entity.position += particle.velocity * delta
            let spin = simd_length(particle.angularVelocity) * delta
            if spin > 0.0001 {
                particle.entity.orientation *= simd_quatf(
                    angle: spin,
                    axis: simd_normalize(particle.angularVelocity)
                )
            }

            let fade = max(0.15, 1 - Float(age / lifetime))
            particle.entity.scale = SIMD3(repeating: fade)
            next.append(particle)
        }

        particles = next
    }

    func clear() {
        for particle in particles {
            particle.entity.removeFromParent()
        }
        particles.removeAll()
    }
}
