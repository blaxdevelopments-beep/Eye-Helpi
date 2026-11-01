//
//  ContentView.swift
//  Eye~Helpi
//

import Combine
import SwiftUI

enum AppTab: String {
    case chat, telemetry, deviceHub, setup
}

struct ContentView: View {
    @State private var selectedTab: AppTab = .chat
    @ObservedObject private var predictive = PredictiveEngine.shared
    @Environment(\.scenePhase) private var scenePhase

    /// The minute-by-minute check-in sweep, armed only while the app is in
    /// the foreground.
    @State private var checkInTimer: AnyCancellable?

    var body: some View {
        TabView(selection: $selectedTab) {
            AgentChatView()
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
                }
                .tag(AppTab.chat)
            NavigationStack {
                TelemetryConsoleView()
            }
            .tabItem {
                Label("Telemetry", systemImage: "speedometer")
            }
            .tag(AppTab.telemetry)
            DeviceHubView()
                .tabItem {
                    Label("Device Hub", systemImage: "eye.trianglebadge.exclamationmark")
                }
                .tag(AppTab.deviceHub)
            AgentSetupView()
                .tabItem {
                    Label("Setup", systemImage: "gearshape.fill")
                }
                .tag(AppTab.setup)
        }
        .tint(EyeTheme.accent)
        .preferredColorScheme(.dark)
        // The dismissible card for the daily proactive check-in greeting.
        .overlay(alignment: .top) {
            if let checkIn = predictive.pendingCheckIn {
                CheckInCard(message: checkIn.message) {
                    withAnimation(.spring(duration: 0.25)) {
                        predictive.dismissCheckIn()
                    }
                }
                .padding(.top, 8)
                .padding(.horizontal)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            if scenePhase == .active {
                predictive.considerCheckIn()
                startCheckInTimer()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Check-ins fire only while the app is in the foreground.
            if phase == .active {
                predictive.considerCheckIn()
                startCheckInTimer()
            } else {
                stopCheckInTimer()
            }
        }
        // Deep links: eyehelpi://chat opens the Chat tab, and
        // eyehelpi://chat?text=Hello pre-fills the draft with "Hello".
        .onOpenURL { url in
            guard url.scheme?.lowercased() == "eyehelpi" else { return }
            selectedTab = .chat
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let text = components.queryItems?.first(where: { $0.name == "text" })?.value,
               !text.isEmpty {
                NotificationCenter.default.post(
                    name: Notification.Name("eyehelpi.incomingDraft"),
                    object: nil,
                    userInfo: ["text": text]
                )
            }
        }
    }

    /// The minute-by-minute sweep so a check-in still fires when the
    /// preferred hour passes while the app is open.
    private func startCheckInTimer() {
        guard checkInTimer == nil else { return }
        checkInTimer = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                predictive.considerCheckIn()
            }
    }

    private func stopCheckInTimer() {
        checkInTimer?.cancel()
        checkInTimer = nil
    }
}

/// The dismissible card shown when Eye~Helpi delivers its daily proactive
/// check-in.
private struct CheckInCard: View {

    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            EyeSigil()
            VStack(alignment: .leading, spacing: 4) {
                EyeTheme.hud("proactive check-in")
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss check-in")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(EyeTheme.hairline)
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }
}

#Preview {
    ContentView()
}