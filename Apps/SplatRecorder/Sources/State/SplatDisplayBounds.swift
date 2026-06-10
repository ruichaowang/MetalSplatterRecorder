import Foundation
import simd

struct SplatDisplayBounds {
    struct Bounds {
        let min: SIMD3<Float>
        let max: SIMD3<Float>

        var center: SIMD3<Float> {
            (min + max) * 0.5
        }

        var diagonal: Float {
            simd_length(max - min)
        }
    }

    static func rawBounds(for positions: [SIMD3<Float>]) -> Bounds {
        guard !positions.isEmpty else {
            return Bounds(min: .zero, max: .zero)
        }

        var minPoint = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxPoint = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for position in positions {
            minPoint = simd_min(minPoint, position)
            maxPoint = simd_max(maxPoint, position)
        }
        return Bounds(min: minPoint, max: maxPoint)
    }

    static func robustBounds(for positions: [SIMD3<Float>]) -> Bounds {
        let visibleIndices = robustVisibleIndices(for: positions)
        guard visibleIndices.count != positions.count else {
            return rawBounds(for: positions)
        }
        return rawBounds(for: visibleIndices.map { positions[$0] })
    }

    static func robustVisibleIndices(for positions: [SIMD3<Float>]) -> [Int] {
        let raw = rawBounds(for: positions)
        guard positions.count >= 32 else { return Array(positions.indices) }

        let center = medianCenter(for: positions)
        let distances = positions.map { position in simd_distance(position, center) }
        let sortedDistances = distances.sorted()

        guard let threshold = separatedShellThreshold(in: sortedDistances, rawDiagonal: raw.diagonal) else {
            return Array(positions.indices)
        }

        let kept = distances.indices.filter { distances[$0] <= threshold }
        guard kept.count >= positions.count / 2 else { return Array(positions.indices) }
        return kept
    }

    private static func medianCenter(for positions: [SIMD3<Float>]) -> SIMD3<Float> {
        SIMD3<Float>(
            median(positions.map(\.x)),
            median(positions.map(\.y)),
            median(positions.map(\.z))
        )
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) * 0.5
        }
        return sorted[middle]
    }

    private static func separatedShellThreshold(in distances: [Float], rawDiagonal: Float) -> Float? {
        guard distances.count >= 32, rawDiagonal > 0 else { return nil }

        let start = max(1, distances.count * 8 / 10)
        let end = max(start, min(distances.count - 2, distances.count * 995 / 1000))
        let minimumGap = max(rawDiagonal * 0.05, 1)

        var best: (index: Int, gap: Float)?
        for index in start...end {
            let current = distances[index]
            let next = distances[index + 1]
            let gap = next - current
            let ratio = next / max(current, 0.001)
            guard gap >= minimumGap, ratio >= 2.5 else { continue }
            if best == nil || gap > best!.gap {
                best = (index, gap)
            }
        }

        guard let best else { return nil }
        return distances[best.index]
    }
}
