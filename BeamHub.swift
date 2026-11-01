//
//  BeamHub.swift
//  Eye~Helpi
//
//  Bluetooth/nearby file beaming between Eye~Helpi devices via Apple's
//  Multipeer Connectivity (Bluetooth + Wi-Fi Direct under the hood).
//  Honest scope: iOS permits peer-to-peer transfer only to other Apple
//  devices running this app — raw Bluetooth file pushes to arbitrary
//  devices (the OPP profile Android apps use) are blocked by Apple.
//
//  Every beam goes through AskGate first: Eye~Helpi asks its secondary
//  user (audio and/or display, per preference) before transmitting.
//

import Foundation
import MultipeerConnectivity

@MainActor
final class BeamHub: NSObject, ObservableObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {

    static let serviceType = "eyehelpi-beam"

    @Published var isBeaming = false
    @Published var nearbyPeers: [MCPeerID] = []
    @Published var lastResult = ""

    private let peerID = MCPeerID(displayName: "Eye~Helpi")
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    override init() {
        super.init()
        session = MCSession(
            peer: peerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        session.delegate = self
    }

    func startSharing() {
        advertiser = MCNearbyServiceAdvertiser(
            peer: peerID, discoveryInfo: nil, serviceType: Self.serviceType
        )
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()
        isBeaming = true
    }

    func stopSharing() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        advertiser = nil
        browser = nil
        isBeaming = false
    }

    /// Beams a local file to every connected peer.
    /// AskGate asks permission BEFORE this is reached.
    func beam(fileURL: URL) {
        guard !session.connectedPeers.isEmpty else {
            lastResult = "No nearby Eye~Helpi device connected yet. Open Eye~Helpi on the other device, then try again."
            return
        }
        for peer in session.connectedPeers {
            session.sendResource(
                at: fileURL,
                withName: fileURL.lastPathComponent,
                toPeer: peer
            ) { [weak self] error in
                Task { @MainActor in
                    if let error {
                        self?.lastResult = "Beam to \(peer.displayName) failed: \(error.localizedDescription)"
                    } else {
                        self?.lastResult = "Beamed \(fileURL.lastPathComponent) to \(peer.displayName)."
                    }
                }
            }
        }
    }
}

// MARK: - MultipeerConnectivity delegates

extension BeamHub {

    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            self.nearbyPeers = session.connectedPeers
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        // Incoming raw data is unused; file beams arrive via didFinishReceivingResource.
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        // Incoming streams are unused; file beams arrive via didFinishReceivingResource.
    }

    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        // Progress display optional.
    }

    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        Task { @MainActor in
            if let error {
                self.lastResult = "Received \(resourceName) with an error: \(error.localizedDescription)"
            } else {
                self.lastResult = "Received \(resourceName) from \(peerID.displayName)."
            }
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Auto-accept invites from Eye~Helpi peers; what gets beamed is gated by AskGate.
        Task { @MainActor in
            invitationHandler(true, self.session)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            if !self.nearbyPeers.contains(peerID) {
                self.nearbyPeers.append(peerID)
            }
            browser.invitePeer(peerID, to: self.session, withContext: nil, timeout: 15)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.nearbyPeers.removeAll { $0 == peerID }
        }
    }
}