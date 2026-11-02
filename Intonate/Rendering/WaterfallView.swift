import MetalKit
import SwiftUI

/// Hosts the Metal view. All the view's work happens in `Coordinator` on the main thread, driven by
/// MTKView's display cadence and not by SwiftUI's update cycle.
struct WaterfallView: UIViewRepresentable {
    /// Nil when this environment has no usable Metal device.
    let renderer: WaterfallRenderer?
    let scene: WaterfallScene
    var monitor: PipelineMonitor?

    func makeCoordinator() -> Coordinator {
        Coordinator(renderer: renderer, scene: scene, monitor: monitor)
    }

    func makeUIView(context: Context) -> UIView {
        guard let renderer else { return Self.unavailableLabel() }
        let view = MTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = WaterfallRenderer.pixelFormat
        view.clearColor = MTLClearColor(red: 0.02, green: 0.016, blue: 0.035, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.isOpaque = true
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Spectrogram with pitch trail"
        view.accessibilityIdentifier = "waterfall"
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.scene = scene
    }

    private static func unavailableLabel() -> UIView {
        let label = UILabel()
        label.text = "The spectrogram needs Metal, which is not available here."
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var scene: WaterfallScene

        private let renderer: WaterfallRenderer?
        private let monitor: PipelineMonitor?
        private var lastDraw: CFTimeInterval?

        init(renderer: WaterfallRenderer?, scene: WaterfallScene, monitor: PipelineMonitor?) {
            self.renderer = renderer
            self.scene = scene
            self.monitor = monitor
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let renderer, let commandBuffer = renderer.queue.makeCommandBuffer() else { return }
            guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else {
                monitor?.recordDroppedDrawable()
                return
            }
            let began = mach_continuous_time()
            let now = CACurrentMediaTime()
            renderer.draw(
                into: commandBuffer,
                pass: pass,
                size: view.drawableSize,
                scene: scene,
                frameTime: now
            )
            commandBuffer.present(drawable)

            if let monitor {
                monitor.recordFrame(
                    intervalMs: lastDraw.map { (now - $0) * 1_000 },
                    encodeMs: HostClock.milliseconds(from: began, to: mach_continuous_time()),
                    frameWaitMs: renderer.frameWaitMilliseconds
                )
                commandBuffer.addCompletedHandler { buffer in
                    let duration = buffer.gpuEndTime - buffer.gpuStartTime
                    if duration > 0 { monitor.recordGPU(ms: duration * 1_000) }
                }
            }
            lastDraw = now
            commandBuffer.commit()
        }
    }
}
