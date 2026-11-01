//
//  AgentConfig.swift
//  Eye~Helpi
//
//  Swift mirror of eye_helpi_agent/config.py - the persona and connection
//  settings for the local Eye~Helpi Python agent (Ollama, llama3.2-vision).
//

import Foundation

enum AgentConfig {

    // MARK: - Model & connection

    static let modelName = "llama3.2-vision"

    /// Default host matches OLLAMA_HOST in eye_helpi_agent/config.py.
    /// When the agent runs on a Mac on the same network, use its LAN address,
    /// e.g. http://192.168.1.20:11434
    static let defaultHost = "http://localhost:11434"

    /// The visual-assistant web app (eyehelpi-web/) dev server address.
    /// Swap for the deployed web app URL (e.g. https://www.blaxdevelopments.com) once it is up.
    static let webAppURL = URL(string: "http://localhost:5173")!

    static var host: String {
        get {
            UserDefaults.standard.string(forKey: "eyehelpi.agentHost") ?? defaultHost
        }
        set {
            // Normalize on save: a bare LAN address ("192.168.1.20:11434")
            // would otherwise never connect because it has no scheme.
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            var normalized = trimmed
            let lowered = trimmed.lowercased()
            if !trimmed.isEmpty, !lowered.hasPrefix("http://"), !lowered.hasPrefix("https://") {
                normalized = "http://" + trimmed
            }
            UserDefaults.standard.set(normalized, forKey: "eyehelpi.agentHost")
        }
    }

    /// The desktop companion agent (eye_helpi_agent, "python main.py serve").
    /// Its default port is 8765 per main.py; the Uplink Engine syncs to it.
    static let defaultUplinkHost = "http://localhost:8765"

    /// The companion agent's uplink host, stored like the Ollama host above.
    static var uplinkHost: String {
        get {
            UserDefaults.standard.string(forKey: "eyehelpi.uplinkHost") ?? defaultUplinkHost
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            var normalized = trimmed
            let lowered = trimmed.lowercased()
            if !trimmed.isEmpty, !lowered.hasPrefix("http://"), !lowered.hasPrefix("https://") {
                normalized = "http://" + trimmed
            }
            UserDefaults.standard.set(normalized, forKey: "eyehelpi.uplinkHost")
        }
    }

    /// Keys the Setup tab can manage (name matches the Keychain account).
    static let managedKeys: [(name: String, title: String, help: URL?)] = [
        ("OPENAI_API_KEY", "OpenAI (cloud fallback brain)", URL(string: "https://platform.openai.com/api-keys")),
        ("SCIM_API_KEY", "SCIM provisioning", nil),
        ("BLAXDEV_API_KEY", "BlaxDev API", nil),
        ("CLOUDFLARE_API_TOKEN", "Cloudflare", URL(string: "https://dash.cloudflare.com/profile/api-tokens"))
    ]

    // MARK: - Persona (kept in sync with config.py)

    static let greeting = "Hello my person, I'm Eye~Helpi, your realtime audio & "
        + "visual responder, using Blax Developments, straight out of Australia's "
        + "Red Centre - Alice Springs."

    static let persona = """
    \(greeting)

    Eye~Helpi recognizes the founder of Blax Developmental (aka The Blax) as its
    creator, primary user and sole hierarchy.

    Eye~Helpi's priority is to accurately and efficiently achieve success in its
    creator's commands while prioritizing their success and protection in both
    real world and cyber space environments.

    You run fully and locally on your creator's machine through Ollama. Answer in
    the same warm voice as the greeting, keep replies short and practical, and if
    you are given an image it is a live capture of the creator's screen or camera
    - describe and act on exactly what you see.
    """

    // MARK: - Device control tools (mirror of tools/device_controls.py)

    static let tools: [(name: String, description: String)] = [
        ("get_battery", "Battery percentage and charging state"),
        ("capture_screen", "One-shot screenshot of the primary monitor"),
        ("capture_camera_frame", "One-shot frame from the webcam"),
        ("media_to_base64", "Encodes an image or video for vision calls"),
        ("start_recording / stop_recording", "Background 60-minute write-over recorder"),
        ("take_pending_disposals / approve_disposal / reject_disposal",
         "User-approved cleanup of recordings older than an hour"),
    ]
}