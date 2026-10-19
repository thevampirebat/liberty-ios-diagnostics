import SwiftUI
import MetalKit
import AVFoundation
import UIKit
import QuartzCore

@MainActor
final class Diagnostics: ObservableObject {
    @Published var lines: [String] = []
    @Published var metalStatus = "Waiting for a drawable…"
    @Published var audioStatus = "Not tested"
    @Published var storageStatus = "Not tested"
    let logURL: URL
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var audioAttached = false

    init() {
        logURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("liberty-ios-diagnostic.log")
        // Start a fresh report for each launch.
        do { try Data().write(to: logURL, options: .atomic) }
        catch { lines.append("Cannot create report: \(error.localizedDescription)") }
        record("Native diagnostics 0.1 — this app does not contain the GTA IV runtime.")
        record("Device: \(UIDevice.current.model), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        record("Physical RAM: \(ProcessInfo.processInfo.physicalMemory / 1_048_576) MiB")
        checkStorage()
    }

    func record(_ text: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(text)"
        lines.append(line)
        do {
            let file = try FileHandle(forWritingTo: logURL)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            storageStatus = "Log write failed: \(error.localizedDescription)"
        }
    }

    func checkStorage() {
        let testURL = logURL.deletingLastPathComponent().appendingPathComponent("storage-probe.txt")
        let expected = Data("Liberty iOS storage check".utf8)
        do {
            try expected.write(to: testURL, options: .atomic)
            guard try Data(contentsOf: testURL) == expected else {
                throw NSError(domain: "Diagnostics", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Read-back mismatch"])
            }
            try FileManager.default.removeItem(at: testURL)
            storageStatus = "PASS: write, read and delete"
            record("Documents storage: \(storageStatus)")
        } catch {
            storageStatus = "FAIL: \(error.localizedDescription)"
            record("Documents storage: \(storageStatus)")
        }
    }

    func playTone() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12_000),
                  let channel = buffer.floatChannelData?[0] else {
                throw NSError(domain: "Diagnostics", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Audio buffer unavailable"])
            }
            buffer.frameLength = buffer.frameCapacity
            for i in 0..<Int(buffer.frameLength) {
                let fade = min(1.0, min(Double(i) / 240.0, Double(Int(buffer.frameLength) - i) / 240.0))
                channel[i] = Float(sin(Double(i) * 2.0 * .pi * 440.0 / 48_000.0) * 0.12 * fade)
            }
            if !audioAttached {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                audioAttached = true
            }
            player.stop()
            if !engine.isRunning { try engine.start() }
            player.scheduleBuffer(buffer)
            player.play()
            audioStatus = "Tone scheduled — confirm you heard it"
            record("Audio engine started; 0.25-second 440 Hz tone scheduled.")
            record("Audio output: \(session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ", "))")
        } catch {
            audioStatus = "FAIL: \(error.localizedDescription)"
            record("Audio: \(audioStatus)")
        }
    }

    func stopAudio() {
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

@MainActor
struct MetalPanel: UIViewRepresentable {
    let diagnostics: Diagnostics

    func makeCoordinator() -> Coordinator { Coordinator(diagnostics) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.preferredFramesPerSecond = 30
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.delegate = context.coordinator
        context.coordinator.queue = view.device?.makeCommandQueue()
        if let device = view.device {
            diagnostics.record("Metal device: \(device.name)")
            diagnostics.record("Metal command queue: \(context.coordinator.queue == nil ? "unavailable" : "created")")
        } else {
            diagnostics.metalStatus = "FAIL: no Metal device"
            diagnostics.record(diagnostics.metalStatus)
        }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}

    final class Coordinator: NSObject, MTKViewDelegate {
        let diagnostics: Diagnostics
        var queue: MTLCommandQueue?
        var reported = false
        let start = CACurrentMediaTime()

        init(_ diagnostics: Diagnostics) { self.diagnostics = diagnostics }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let pass = view.currentRenderPassDescriptor,
                  let command = queue?.makeCommandBuffer() else { return }
            let t = CACurrentMediaTime() - start
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(
                red: 0.12 + 0.1 * sin(t), green: 0.25 + 0.15 * sin(t * 0.7),
                blue: 0.65 + 0.2 * sin(t * 0.4), alpha: 1)
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.endEncoding()
            command.present(drawable)
            if !reported {
                reported = true
                command.addCompletedHandler { [weak self] completed in
                    let message = completed.status == .completed
                        ? "PASS: GPU completed a display command"
                        : "FAIL: \(completed.error?.localizedDescription ?? "Metal command failed")"
                    Task { @MainActor [weak self] in
                        self?.diagnostics.metalStatus = message
                        self?.diagnostics.record("Metal: " + message)
                    }
                }
            }
            command.commit()
        }
    }
}

@MainActor
struct ContentView: View {
    @ObservedObject var diagnostics: Diagnostics
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Liberty iOS diagnostics").font(.largeTitle.bold())
                Text("Device checks only. No GTA IV game code is running.")
                    .foregroundStyle(.secondary)
                MetalPanel(diagnostics: diagnostics)
                    .frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 12))
                Text("The panel should change colour smoothly.").font(.caption)
                Text("Metal: \(diagnostics.metalStatus)")
                Text("Storage: \(diagnostics.storageStatus)")
                Text("Audio: \(diagnostics.audioStatus)")
                HStack {
                    Button("Play test tone") { diagnostics.playTone() }
                        .buttonStyle(.borderedProminent)
                    Button("I heard it") {
                        diagnostics.audioStatus = "PASS: confirmed by user"
                        diagnostics.record("User confirmed audible test tone.")
                    }.buttonStyle(.bordered)
                }
                Button("Repeat storage test") { diagnostics.checkStorage() }
                ShareLink(item: diagnostics.logURL) { Label("Share diagnostic log", systemImage: "square.and.arrow.up") }
                Divider()
                Text(diagnostics.lines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }.padding()
        }
    }
}

@main
@MainActor
struct NativeDiagnosticsApp: App {
    @StateObject private var diagnostics = Diagnostics()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ContentView(diagnostics: diagnostics)
                .onChange(of: scenePhase) { phase in
                    diagnostics.record("Scene: \(String(describing: phase))")
                    if phase != .active { diagnostics.stopAudio() }
                }
        }
    }
}
