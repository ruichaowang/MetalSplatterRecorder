import SwiftUI
import simd

struct CameraDebugHUD: View {
    let debugState: CameraDebugState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Camera Debug")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))

            if let after = debugState.lastAfter {
                Text("target \(format(after.target))")
                Text("eye    \(format(after.eye))")
                Text("yaw/pitch/dist \(degrees(after.yaw)) \(degrees(after.pitch)) \(format(after.distance))")
            }

            if let probe = debugState.lastProbe {
                Text("target-screen \(format(probe.targetScreenPixel))")
                Text("center-screen \(format(probe.splatCenterScreenPixel))")
                Text("target-center \(format(probe.targetToSplatCenterDistance))")
                Text("nearest-target \(format(probe.nearestPointToTargetDistance))")
                Text("nearest-ray \(format(probe.nearestPointToCenterRayDistance))")
                Text("samples \(probe.sampledPointCount)")
            }

            if let event = debugState.lastEvent {
                Text("event \(event.rawValue) dx \(format(debugState.lastInput.dx)) dy \(format(debugState.lastInput.dy))")
                Text("targetDelta \(format(debugState.lastTargetDelta))")
            }

            if let path = debugState.logFileURL?.path {
                Text("log \(path)")
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            if let path = debugState.lastBundleURL?.path {
                Text("bundle \(path)")
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            if let error = debugState.lastError {
                Text("log error \(error)")
                    .foregroundStyle(.orange)
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.primary)
        .padding(8)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
        .frame(maxWidth: 360, alignment: .leading)
    }

    private func format(_ value: SIMD3<Float>) -> String {
        "(\(format(value.x)), \(format(value.y)), \(format(value.z)))"
    }

    private func format(_ value: SIMD2<Float>?) -> String {
        guard let value else { return "nil" }
        return "(\(format(value.x)), \(format(value.y)))"
    }

    private func format(_ value: Float?) -> String {
        guard let value else { return "nil" }
        return format(value)
    }

    private func format(_ value: Float) -> String {
        String(format: "%.3f", value)
    }

    private func degrees(_ radians: Float) -> String {
        "\(format(radians * 180 / .pi))deg"
    }
}

struct CameraDebugOverlay: View {
    let debugState: CameraDebugState

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let viewport = debugState.viewportSize

            ZStack {
                CenterCross()
                    .stroke(.white.opacity(0.75), lineWidth: 1)

                if let pixel = debugState.lastProbe?.targetScreenPixel {
                    Marker(position: point(pixel, viewport: viewport, size: size), color: .red, label: "target")
                }

                if let pixel = debugState.lastProbe?.splatCenterScreenPixel {
                    Marker(position: point(pixel, viewport: viewport, size: size), color: .green, label: "center")
                }

                if let pixel = debugState.lastProbe?.nearestPointToCenterRayScreenPixel {
                    Marker(position: point(pixel, viewport: viewport, size: size), color: .blue, label: "ray")
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func point(_ pixel: SIMD2<Float>, viewport: SIMD2<Int>, size: CGSize) -> CGPoint {
        guard viewport.x > 0, viewport.y > 0 else {
            return CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        }
        return CGPoint(
            x: CGFloat(pixel.x / Float(viewport.x)) * size.width,
            y: CGFloat(pixel.y / Float(viewport.y)) * size.height
        )
    }
}

private struct CenterCross: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: CGPoint(x: center.x - 8, y: center.y))
        path.addLine(to: CGPoint(x: center.x + 8, y: center.y))
        path.move(to: CGPoint(x: center.x, y: center.y - 8))
        path.addLine(to: CGPoint(x: center.x, y: center.y + 8))
        return path
    }
}

private struct Marker: View {
    let position: CGPoint
    let color: Color
    let label: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            Circle()
                .stroke(color, lineWidth: 2)
                .frame(width: 14, height: 14)
                .position(position)
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .position(x: position.x + 24, y: position.y - 8)
        }
    }
}
