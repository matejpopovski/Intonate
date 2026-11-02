import Foundation
import UIKit

/// With `--measure <seconds>`, runs the real app in demo mode and saves its timings to Documents, from
/// where `scripts/measure-simulator.sh` copies them into `results/`.
@MainActor
final class MeasurementRun {
    private let session: TrainerSession
    private let seconds: Double

    init(session: TrainerSession, seconds: Double) {
        self.session = session
        self.seconds = seconds
    }

    func begin() {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            finish()
        }
    }

    private func finish() {
        guard let monitor = session.monitor else { return }
        var runtime = UIDevice.current.systemName + " " + UIDevice.current.systemVersion
        var device = UIDevice.current.model
        #if targetEnvironment(simulator)
            runtime += " simulator"
            device = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? device
        #endif
        #if DEBUG
            let build = "Debug"
        #else
            let build = "Release"
        #endif
        let report = monitor.report(
            build: build,
            device: device,
            runtime: runtime,
            host: ProcessInfo.processInfo.environment["INTONATE_HOST"] ?? "not recorded",
            seconds: seconds,
            droppedSamples: session.droppedSamples,
            rendererSetupMs: session.rendererSetupMilliseconds.map { $0.rounded() },
            note:
                "Measured in the iOS Simulator on the host CPU and GPU with a synthesized voice. "
                + "These are not phone figures, and they exclude audio capture hardware and display scan-out."
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report),
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let url = folder.appendingPathComponent("simulator_timing.json")
        try? (data + Data("\n".utf8)).write(to: url)
        print("INTONATE_MEASUREMENT_DONE \(url.path)")
    }
}
