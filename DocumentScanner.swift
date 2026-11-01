//
//  DocumentScanner.swift
//  Eye~Helpi
//
//  VisionKit document scanner: scan a paper document with the camera and
//  hand the pages to the brain ("read this and tell me what it says").
//  Wraps VNDocumentCameraViewController - works on the real iPhone.
//

import SwiftUI
import VisionKit
import UIKit

@MainActor
struct DocumentScannerView: UIViewControllerRepresentable {

    let completion: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {

        let completion: ([UIImage]) -> Void

        init(completion: @escaping ([UIImage]) -> Void) {
            self.completion = completion
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            controller.dismiss(animated: true)
            let pages = (0..<scan.pageCount).compactMap { scan.imageOfPage(at: $0) }
            completion(pages)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            controller.dismiss(animated: true)
        }
    }
}