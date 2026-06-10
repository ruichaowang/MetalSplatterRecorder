import SwiftUI
import simd

/// A SuperSplat-style orientation gizmo rendered with SwiftUI Canvas.
/// Shows 6 circles representing the 6 axis-aligned directions, color-coded
/// by axis (red=X, green=Y, blue=Z), with real-time position updates from
/// the camera's world matrix.
struct ViewCube: View {
    /// Camera-to-world matrix (viewMatrix.inverse).
    let cameraMatrix: simd_float4x4
    /// Whether the cube is dimmed (during recording).
    let isDimmed: Bool
    /// Callback when user taps a circle to align to a preset.
    let onSelectPreset: (ViewPreset) -> Void

    private let drawRadius: CGFloat = 38
    private let circleRadius: CGFloat = 10

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)

            // Extract camera axes from the camera-to-world matrix
            let right   = SIMD3<Float>(cameraMatrix.columns.0.x, cameraMatrix.columns.0.y, cameraMatrix.columns.0.z)
            let up      = SIMD3<Float>(cameraMatrix.columns.1.x, cameraMatrix.columns.1.y, cameraMatrix.columns.1.z)
            let forward = SIMD3<Float>(cameraMatrix.columns.2.x, cameraMatrix.columns.2.y, cameraMatrix.columns.2.z)

            // Project 3D axis vector to 2D screen position. Y is flipped.
            func project(_ v: SIMD3<Float>) -> CGPoint {
                CGPoint(x: CGFloat(v.x) * drawRadius + center.x,
                        y: CGFloat(-v.y) * drawRadius + center.y)
            }

            // Build all 6 circles with metadata
            struct CircleData {
                let pos: CGPoint
                let z: Float
                let color: Color
                let isFilled: Bool
                let label: String
                let preset: ViewPreset
            }

            let circles: [CircleData] = [
                .init(pos: project(right),   z: right.z,   color: .red,   isFilled: true,  label: "X", preset: .right),
                .init(pos: project(-right),  z: -right.z,  color: .red,   isFilled: false, label: "",  preset: .left),
                .init(pos: project(up),      z: up.z,      color: .green, isFilled: true,  label: "Y", preset: .top),
                .init(pos: project(-up),     z: -up.z,     color: .green, isFilled: false, label: "",  preset: .bottom),
                .init(pos: project(forward), z: forward.z, color: .blue,  isFilled: true,  label: "Z", preset: .front),
                .init(pos: project(-forward),z: -forward.z,color: .blue,  isFilled: false, label: "",  preset: .back),
            ]

            // Sort by Z-depth for painter's algorithm (far first, near last)
            let sorted = circles.sorted { $0.z < $1.z }

            let opacity: CGFloat = isDimmed ? 0.4 : 1.0

            // Draw axis lines (center to each circle)
            for cd in sorted {
                var linePath = Path()
                linePath.move(to: center)
                linePath.addLine(to: cd.pos)
                context.stroke(linePath, with: .color(cd.color.opacity(0.3 * opacity)), lineWidth: 1.2)
            }

            // Draw circles
            for cd in sorted {
                let rect = CGRect(x: cd.pos.x - circleRadius, y: cd.pos.y - circleRadius,
                                  width: circleRadius * 2, height: circleRadius * 2)
                let circlePath = Path(ellipseIn: rect)

                if cd.isFilled {
                    context.fill(circlePath, with: .color(cd.color.opacity(opacity)))
                    context.stroke(circlePath, with: .color(cd.color.opacity(opacity)), lineWidth: 1.5)
                    if !cd.label.isEmpty {
                        let text = Text(cd.label)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                        context.draw(text, at: cd.pos)
                    }
                } else {
                    context.fill(circlePath, with: .color(Color(white: 0.1)))
                    context.stroke(circlePath, with: .color(cd.color.opacity(0.6 * opacity)), lineWidth: 1.5)
                }
            }
        }
        .frame(width: 100, height: 100)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .opacity(isDimmed ? 0.4 : 0.85)
        )
        .contentShape(Rectangle())
        .gesture(
            SpatialTapGesture()
                .onEnded { value in
                    handleTap(at: value.location, in: CGSize(width: 100, height: 100))
                }
        )
    }

    /// Convert tap location to nearest circle and fire the preset callback.
    private func handleTap(at location: CGPoint, in size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        // Reconstruct circle positions (same projection as in Canvas)
        let right   = SIMD3<Float>(cameraMatrix.columns.0.x, cameraMatrix.columns.0.y, cameraMatrix.columns.0.z)
        let up      = SIMD3<Float>(cameraMatrix.columns.1.x, cameraMatrix.columns.1.y, cameraMatrix.columns.1.z)
        let forward = SIMD3<Float>(cameraMatrix.columns.2.x, cameraMatrix.columns.2.y, cameraMatrix.columns.2.z)

        func project(_ v: SIMD3<Float>) -> CGPoint {
            CGPoint(x: CGFloat(v.x) * drawRadius + center.x,
                    y: CGFloat(-v.y) * drawRadius + center.y)
        }

        let presets: [(CGPoint, ViewPreset)] = [
            (project(right),   .right),
            (project(-right),  .left),
            (project(up),      .top),
            (project(-up),     .bottom),
            (project(forward), .front),
            (project(-forward),.back),
        ]

        // Find closest circle within threshold
        let threshold: CGFloat = circleRadius + 4
        var best: (CGFloat, ViewPreset)? = nil
        for (pos, preset) in presets {
            let dx = location.x - pos.x
            let dy = location.y - pos.y
            let dist = sqrt(dx*dx + dy*dy)
            if dist < threshold && (best == nil || dist < best!.0) {
                best = (dist, preset)
            }
        }

        if let (_, preset) = best {
            onSelectPreset(preset)
        }
    }
}
