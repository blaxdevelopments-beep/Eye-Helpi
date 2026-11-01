//
//  DeviceHubView.swift
//  Eye~Helpi
//
//  Real device-hardware integration: live camera (AVFoundation), always-on
//  "live watch" mode with on-device pre-scanning (Vision framework: faces +
//  readable text before every brain call), on-demand and automatic frame
//  analysis by the Ollama/OpenAI brain, spoken reports, voice commands
//  (see VoiceCommandMonitor) and haptic feedback.
//

import AVFoundation
import SwiftUI
import UIKit
import Vision

// MARK: - Camera controller

final class CameraController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    @Published var authorizationDenied = false
    @Published var isRunning = false
    @Published var setupError: String?
    @Published var latestFrame: UIImage?

    // Created lazily: the Device Hub tab is not the entry tab, so the camera
    // session should not be built while the app is launching.
    lazy var session = AVCaptureSession()

    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "eyehelpi.camera")
    private var lastCaptureTime = Date.distantPast

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                if granted {
                    self.configureAndStart()
                } else {
                    self.authorizationDenied = true
                }
            }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning {
                self.session.stopRunning()
                DispatchQueue.main.async { self.isRunning = false }
            }
        }
    }

    private func configureAndStart() {
        session.beginConfiguration()
        session.sessionPreset = .high

        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)
        guard let device, let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            setupError = "No camera is available on this device."
            return
        }
        session.addInput(input)

        if session.canAddOutput(output) {
            output.setSampleBufferDelegate(self, queue: queue)
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            session.addOutput(output)
            output.connection(with: .video)?.videoRotationAngle = 90
        }
        session.commitConfiguration()

        queue.async {
            if !self.session.isRunning {
                self.session.startRunning()
                DispatchQueue.main.async { self.isRunning = true }
            }
        }
    }

    // Runs on the capture queue; throttle to roughly one frame per second.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRunning else { return }
        let now = Date()
        guard now.timeIntervalSince(lastCaptureTime) > 1.0,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        lastCaptureTime = now

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let image = UIImage(cgImage: cgImage)
        DispatchQueue.main.async { self.latestFrame = image }
    }
}

// MARK: - Image helpers

extension UIImage {
    /// Downscaled JPEG as a base64 string for Ollama vision calls.
    func jpegBase64(maxDimension: CGFloat = 1280) -> String? {
        let scale = maxDimension / max(size.width, size.height)
        let target = scale < 1 ? CGSize(width: size.width * scale, height: size.height * scale) : size
        let resized = UIGraphicsImageRenderer(size: target).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.6)?.base64EncodedString()
    }
}

// MARK: - Camera preview

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        guard let previewLayer = view.layer as? AVCaptureVideoPreviewLayer else {
            return view
        }
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

// MARK: - Device Hub screen

struct DeviceHubView: View {

    @StateObject private var camera = CameraController()
    @StateObject private var voice = VoiceCommandMonitor()
    @StateObject private var homeKit = HomeKitStatus()
    @ObservedObject private var voiceOutput = EyeVoice.shared
    @ObservedObject private var predictive = PredictiveEngine.shared

    @State private var sceneReport = ""
    @State private var analyzing = false
    @State private var brain = ""
    @State private var liveWatch = false
    @State private var lastWatchReport = ""
    @State private var showingScanner = false
    @State private var scanning = false
    @State private var analysisTask: Task<Void, Never>?
    @State private var watchTask: Task<Void, Never>?

    // Built on demand at the point of impact - not at view creation.
    private var haptic: UIImpactFeedbackGenerator {
        UIImpactFeedbackGenerator(style: .medium)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    CameraPreviewView(session: camera.session)
                        .aspectRatio(3 / 4, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(Capsule().strokeBorder(EyeTheme.hairline).padding(1).opacity(0))
                        .overlay(alignment: .bottom) {
                            if analyzing {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text("Eye~Helpi is looking...")
                                }
                                .padding(10)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                                .padding(10)
                            }
                        }

                    if camera.authorizationDenied {
                        Label("Camera access is denied. Enable it in Settings > Eye~Helpi to let me see.", systemImage: "video.slash")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let setupError = camera.setupError {
                        Label(setupError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        analyzeScene()
                    } label: {
                        Label("Analyse what I see", systemImage: "eye")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(analyzing || !camera.isRunning)

                    Button {
                        showingScanner = true
                    } label: {
                        Label("Scan a document", systemImage: "doc.text.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(scanning)

                    Toggle(isOn: Binding(
                        get: { liveWatch },
                        set: { setLiveWatch($0) }
                    )) {
                        Label("Live watch - Eye~Helpi reports scene changes every 8 seconds", systemImage: "eye.trianglebadge.exclamationmark")
                            .font(.footnote)
                    }
                    .tint(EyeTheme.accent)

                    if !sceneReport.isEmpty {
                        Text(sceneReport)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    }

                    if !homeKit.homes.isEmpty || homeKit.authorizationDenied {
                        homeKitSection
                    }

                    Divider()

                    voiceSection

                    proactiveSection
                }
                .padding()
            }
            .scrollContentBackground(.hidden)
            .background(EyeTheme.background.ignoresSafeArea())
            .navigationTitle("Device Hub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    StatusChip(
                        text: brain == "cloud" ? "link: cloud" : brain == "ollama" ? "link: ollama" : "link: standby",
                        color: brain == "cloud" ? EyeTheme.accent : brain == "ollama" ? .green : .secondary
                    )
                }
                ToolbarItem(placement: .topBarLeading) {
                    UplinkStatusChip()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        EyeVoice.shared.isEnabled.toggle()
                    } label: {
                        Image(systemName: voiceOutput.isEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    }
                }
            }
            .onAppear {
                camera.start()
                homeKit.refresh()
                predictive.refresh()
                voice.onTrigger = { analyzeScene() }
            }
            .onDisappear {
                camera.stop()
                if voice.isListening { voice.stopListening() }
                watchTask?.cancel()
                watchTask = nil
                analysisTask?.cancel()
                analysisTask = nil
            }
            .sheet(isPresented: $showingScanner) {
                DocumentScannerView { pages in
                    handleScannedDocument(pages)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("eyehelpi.pauseExtras"))) { _ in
                // Autonomous battery protection (one-time consent already given).
                if liveWatch { setLiveWatch(false) }
                if voice.isListening { voice.stopListening() }
            }
        }
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Voice commands", systemImage: "waveform")
                .font(.headline)
            Text("Say \"analyse\", \"what do you see\" or \"describe\" and I read the camera feed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                voice.toggleListening()
            } label: {
                Label(
                    voice.isListening ? "Stop listening" : "Start listening",
                    systemImage: voice.isListening ? "stop.circle.fill" : "mic.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            if !voice.status.isEmpty {
                Text(voice.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !voice.heard.isEmpty {
                Text(voice.heard)
                    .font(.footnote.monospaced())
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - Live watch

    private func setLiveWatch(_ on: Bool) {
        watchTask?.cancel()
        watchTask = nil
        liveWatch = on
        guard on else { return }
        watchTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, !analyzing, camera.isRunning else { continue }
                analyzeScene(quiet: true)
            }
        }
    }

    /// Token-overlap check so the watch heartbeat only speaks up on real change.
    private func isMeaningfullyNew(_ report: String) -> Bool {
        let tokens = Set(
            report.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 }
        )
        let previous = Set(
            lastWatchReport.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 }
        )
        guard !previous.isEmpty else { return true }
        let overlap = Double(tokens.intersection(previous).count)
            / max(1, Double(tokens.union(previous).count))
        return overlap < 0.55
    }

    // MARK: - On-device pre-scan (Vision)

    /// Cheap on-device pass before every brain call: face count and readable
    /// text, so the cloud/local model gets a head start and the answer is
    /// grounded in what the phone itself already knows.
    private func onDeviceScan(for image: UIImage) -> String {
        guard let cgImage = image.cgImage else { return "" }

        let faceRequest = VNDetectFaceRectanglesRequest()
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .fast

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([faceRequest, textRequest])

        var parts: [String] = []
        if let faces = faceRequest.results, !faces.isEmpty {
            parts.append("\(faces.count) face(s) detected on-device")
        }
        if let lines = textRequest.results, !lines.isEmpty {
            let snippets = lines.prefix(5).compactMap { $0.topCandidates(1).first?.string }
            if !snippets.isEmpty {
                parts.append("visible text: \"\(snippets.joined(separator: ", "))\"")
            }
        }
        return parts.isEmpty ? "" : "(\(parts.joined(separator: "; ")))"
    }

    // MARK: - Proactive layer

    /// Learned rhythms + autonomous preventative care (one-time consent).
    private var proactiveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $predictive.checkInsEnabled) {
                Label("Daily check-in around my usual hour", systemImage: "bell.badge")
                    .font(.footnote)
            }
            .tint(EyeTheme.accent)
            Text("When voice is on, Eye~Helpi greets me out loud once a day near the hour I usually check in, with a card on screen.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Toggle(isOn: $predictive.autoPilotEnabled) {
                Label("Autonomous mode — one-time permission to act for me", systemImage: "hands.sparkles.clap")
                    .font(.footnote)
            }
            .tint(EyeTheme.accent)
            Text("When granted once, Eye~Helpi takes only clearly helpful, reversible actions — like easing off when your battery is low. Nothing destructive, ever.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(predictive.suggestions) { suggestion in
                VStack(alignment: .leading, spacing: 2) {
                    Label(
                        suggestion.title,
                        systemImage: suggestion.isAutoActed ? "bolt.shield.fill" : "sparkles"
                    )
                    .font(.footnote.weight(.semibold))
                    Text(suggestion.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(EyeTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(EyeTheme.hairline))
            }
        }
    }

    // MARK: - HomeKit & document scanning

    private var homeKitSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("HomeKit", systemImage: "house.fill")
                .font(.headline)
            if homeKit.authorizationDenied {
                Text("HomeKit access is denied - enable it in Settings > Eye~Helpi.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(homeKit.homes) { home in
                    Label("\(home.name): \(home.accessoryCount) accessories (\(home.poweredOn) on)", systemImage: "lightbulb")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Scan a paper document and hand the first page to the brain to read.
    private func handleScannedDocument(_ pages: [UIImage]) {
        guard let page = pages.first,
              let base64 = page.jpegBase64() else {
            sceneReport = "The scan came back empty - try again, my person."
            return
        }

        analyzing = true
        scanning = true
        sceneReport = ""
        predictive.recordUsage(.documentScan)
        haptic.impactOccurred()

        let service = AgentService(host: AgentConfig.host)
        let content = "Read this scanned document: tell me what it is, transcribe any key text, and summarise what matters. (Eye~Helpi document scan)"
        let messages = [OllamaMessage(role: "user", content: content, images: [base64])]

        analysisTask?.cancel()
        analysisTask = Task {
            defer { analyzing = false; scanning = false }
            do {
                let reply = try await service.streamChat(
                    messages: messages,
                    onDelta: { _ in },
                    onBrain: { brain = $0 }
                )
                let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                sceneReport = trimmed.isEmpty
                    ? "(no reply came back - is the brain reachable?)"
                    : trimmed
                if EyeVoice.shared.isEnabled {
                    EyeVoice.shared.speak(trimmed)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch URLError.cancelled {
                // Superseded - nothing to show.
            } catch is CancellationError {
                // Superseded - nothing to show.
            } catch {
                sceneReport = "I could not read that document (\(error.localizedDescription))."
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    // MARK: - Analysis

    /// Manual analysis (loud: haptic + full report) or watch heartbeat
    /// (quiet: only surfaces and speaks genuinely new scenes).
    private func analyzeScene(quiet: Bool = false) {
        predictive.recordUsage(.sceneAnalysis)
        if !quiet { haptic.impactOccurred() }
        guard let frame = camera.latestFrame else {
            if !quiet {
                sceneReport = "No frame captured yet - give the camera a second, my person."
            }
            return
        }
        guard let base64 = frame.jpegBase64() else { return }

        analyzing = true
        if !quiet { sceneReport = "" }

        let service = AgentService(host: AgentConfig.host)
        let scan = onDeviceScan(for: frame)
        let content = "What do you see? Describe the scene and any readable text. \(scan) (Eye~Helpi vision)"
        let messages = [
            OllamaMessage(role: "user", content: content, images: [base64])
        ]

        analysisTask?.cancel()
        analysisTask = Task {
            defer { analyzing = false }
            do {
                let reply = try await service.streamChat(
                    messages: messages,
                    onDelta: { _ in },
                    onBrain: { brain = $0 }
                )
                let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    if !quiet {
                        sceneReport = "(no reply came back - is llama3.2-vision pulled on the host?)"
                    }
                    return
                }
                if quiet {
                    guard isMeaningfullyNew(trimmed) else { return }
                    lastWatchReport = trimmed
                    sceneReport = trimmed
                    EyeVoice.shared.speak(trimmed)
                } else {
                    sceneReport = trimmed
                    if EyeVoice.shared.isEnabled {
                        EyeVoice.shared.speak(trimmed)
                    }
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch URLError.cancelled {
                // Superseded by a newer analysis - nothing to show.
            } catch is CancellationError {
                // Superseded by a newer analysis - nothing to show.
            } catch {
                if !quiet {
                    sceneReport = "I could not reach my brain at \(AgentConfig.host) (\(error.localizedDescription))."
                }
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

#Preview {
    DeviceHubView()
}