//
//  TelemetryConsoleView.swift
//  Eye~Helpi
//
//  The Telemetry Console: a dark instrument-panel workspace of live model
//  status cards - local SLM memory allocation, token-generation speed with a
//  sparkline, thermal state, battery impact and uplink sync activity.
//
//  Telemetry itself stays memory-lean: the refresh timer runs only while the
//  tab is visible and the app is active (it stops the moment the tab or app
//  leaves the foreground), and the speed history is a small bounded buffer.
//

import Combine
import SwiftUI
import UIKit

// MARK: - Token speed sampler

/// Records streamed-token arrivals so the console can show a live
/// tokens-per-second readout. Only timestamps inside a short window are
/// kept - a few hundred bytes at most, never the tokens themselves.
final class TelemetryHub {

    static let shared = TelemetryHub()

    private let lock = NSLock()
    private var tokenTimes: [TimeInterval] = []
    private let window: TimeInterval = 4

    /// One token (streamed delta) arrived from a generating brain.
    func recordToken() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        tokenTimes.append(now)
        // Drop arrivals older than the window - a tiny bounded ring.
        while tokenTimes.count > 1, now - tokenTimes[0] > window {
            tokenTimes.removeFirst()
        }
        lock.unlock()
    }

    /// Tokens per second across the recent window.
    var tokensPerSecond: Double {
        lock.lock()
        defer { lock.unlock() }
        guard tokenTimes.count > 1, let first = tokenTimes.first else { return 0 }
        let span = ProcessInfo.processInfo.systemUptime - first
        return span > 0 ? Double(tokenTimes.count) / span : 0
    }
}

// MARK: - Console

struct TelemetryConsoleView: View {

    /// Nominal workspace the memory bar is drawn against.
    private static let memoryCeilingMB: Double = 2048
    private static let historyLength = 40

    @ObservedObject private var uplink = UplinkEngine.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var footprintMB: Double = 0
    @State private var speedHistory: [Double] = []
    @State private var timerCancellable: AnyCancellable?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header

                TelemetryCard(title: "local slm", icon: "cpu") {
                    HStack(alignment: .firstTextBaseline) {
                        Text(AgentConfig.modelName)
                            .font(.system(.title3, design: .monospaced).weight(.semibold))
                            .foregroundStyle(EyeTheme.accent)
                        Spacer()
                        Text(generating ? "generating" : "idle")
                            .font(EyeTheme.hudFont)
                            .foregroundStyle(generating ? EyeTheme.accent : .secondary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(footprintMB, format: .number.precision(.fractionLength(0)))
                            .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                        Text("MB ALLOCATED")
                            .font(EyeTheme.hudFont)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    GaugeBar(
                        fraction: min(footprintMB / Self.memoryCeilingMB, 1),
                        color: EyeTheme.accent
                    )
                    EyeTheme.hud("\(Int(footprintMB)) of \(Int(Self.memoryCeilingMB)) MB WORKSPACE")
                }

                HStack(alignment: .top, spacing: 16) {
                    TelemetryCard(title: "token speed", icon: "speedometer") {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(tokensPerSecond, format: .number.precision(.fractionLength(1)))
                                .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                                .foregroundStyle(EyeTheme.accent)
                            Text("TOK/S")
                                .font(EyeTheme.hudFont)
                                .foregroundStyle(.secondary)
                        }
                        Sparkline(samples: speedHistory, color: .green)
                            .frame(height: 28)
                    }

                    TelemetryCard(title: "thermal", icon: "thermometer.medium") {
                        HStack(spacing: 6) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(thermalColor)
                                .shadow(color: thermalColor.opacity(0.9), radius: 3)
                            Text(thermalLabel)
                                .font(.system(.headline, design: .monospaced))
                                .foregroundStyle(thermalColor)
                        }
                        Spacer()
                        EyeTheme.hud("PROCESSING STATE")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(alignment: .top, spacing: 16) {
                    TelemetryCard(title: "battery", icon: "battery.75") {
                        HStack(spacing: 6) {
                            Image(systemName: batteryIcon)
                                .foregroundStyle(batteryColor)
                            Text("\(batteryLevel, specifier: "%.0f")%")
                                .font(.system(.headline, design: .monospaced))
                        }
                        Spacer()
                        EyeTheme.hud(charging ? "CHARGING" : "UNPLUGGED")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    TelemetryCard(title: "uplink", icon: "antenna.radiowaves.left.and.right") {
                        Text(uplinkText)
                            .font(.system(.headline, design: .monospaced))
                            .foregroundStyle(uplinkColor)
                        Spacer()
                        EyeTheme.hud("\(uplink.queuedCount) QUEUED\(lastSyncText)")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .scrollContentBackground(.hidden)
        .background(EyeTheme.background.ignoresSafeArea())
        .navigationTitle("Telemetry")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: startStreaming)
        .onDisappear(perform: stopStreaming)
        .onChange(of: scenePhase) {
            // Streaming continues only while the app itself is active.
            if scenePhase == .active {
                startStreaming()
            } else {
                stopStreaming()
            }
        }
    }

    // MARK: - Header

    /// The pulsing "all systems live" banner above the cards.
    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
                .shadow(color: .green.opacity(0.9), radius: 4)
            EyeTheme.hud("all systems live · streaming 1 hz")
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Live updates

    private func startStreaming() {
        guard timerCancellable == nil else { return }
        tick()
        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { _ in tick() }
    }

    private func stopStreaming() {
        timerCancellable?.cancel()
        timerCancellable = nil
    }

    private func tick() {
        footprintMB = Self.residentFootprintMB()
        speedHistory.append(TelemetryHub.shared.tokensPerSecond)
        if speedHistory.count > Self.historyLength {
            speedHistory.removeFirst(speedHistory.count - Self.historyLength)
        }
    }

    // MARK: - Readouts

    private var generating: Bool { tokensPerSecond > 0.5 }
    private var tokensPerSecond: Double { TelemetryHub.shared.tokensPerSecond }

    private var thermalColor: Color {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .green
        case .fair: return .orange
        case .serious, .critical: return .red
        @unknown default: return .secondary
        }
    }

    private var thermalLabel: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private var batteryLevel: Double {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level < 0 ? 1.0 : Double(level)
    }

    private var charging: Bool {
        UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
    }

    private var batteryColor: Color {
        if charging { return .green }
        return batteryLevel > 0.2 ? EyeTheme.accent : .red
    }

    private var batteryIcon: String {
        charging ? "battery.100.bolt" : "battery.75"
    }

    private var uplinkText: String {
        switch uplink.status {
        case .offline: return "Offline"
        case .ready: return "Ready"
        case .syncing: return "Syncing"
        case .synced: return "Synced"
        }
    }

    private var uplinkColor: Color {
        switch uplink.status {
        case .offline: return .secondary
        case .ready: return .orange
        case .syncing: return EyeTheme.accent
        case .synced: return .green
        }
    }

    private var lastSyncText: String {
        guard let last = uplink.lastSyncedAt else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return " · SYNCED \(formatter.localizedString(for: last, relativeTo: Date()).uppercased())"
    }

    /// The app's current resident footprint (the memory the on-device model
    /// workspace runs inside), read straight from the kernel.
    private static func residentFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / (1024 * 1024)
    }
}

// MARK: - Card & instrument pieces

/// A translucent instrument card in the command-deck look.
private struct TelemetryCard<Content: View>: View {

    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(EyeTheme.accent)
                EyeTheme.hud(title)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(EyeTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(EyeTheme.hairline))
    }
}

/// A thin horizontal gauge bar with a glowing fill.
private struct GaugeBar: View {

    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.15))
                Capsule()
                    .fill(color)
                    .frame(width: max(6, geometry.size.width * fraction))
                    .shadow(color: color.opacity(0.8), radius: 4)
            }
        }
        .frame(height: 6)
    }
}

/// A minimal sparkline: one polyline over the recent samples, glowing.
private struct Sparkline: View {

    let samples: [Double]
    let color: Color

    var body: some View {
        Canvas { context, size in
            // A flat baseline keeps the instrument alive even at rest.
            guard samples.count > 1 else {
                let y = size.height / 2
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: y))
                baseline.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(baseline, with: .color(color.opacity(0.3)), lineWidth: 1.5)
                return
            }
            let peak = max(samples.max() ?? 1, 0.001)
            var line = Path()
            for (index, sample) in samples.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(samples.count - 1)
                let y = size.height * (1 - CGFloat(sample / peak))
                if index == 0 {
                    line.move(to: CGPoint(x: x, y: y))
                } else {
                    line.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
        .shadow(color: color.opacity(0.7), radius: 2)
    }
}

// MARK: - HUD font helper

extension EyeTheme {
    /// Monospaced HUD text at body-ish size for readouts inside cards.
    static let hudFont = Font.system(size: 10, weight: .semibold, design: .monospaced)
}