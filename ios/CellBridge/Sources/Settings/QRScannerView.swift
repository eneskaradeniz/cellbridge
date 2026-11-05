import AVFoundation
import SwiftUI

/// The camera, looking for one QR code; hands its text over once and stops.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    /// There is no camera to use (the permission is checked before this view is shown).
    var onUnavailable: () -> Void = {}

    func makeUIViewController(context: Context) -> ScannerController { ScannerController(onCode: onCode, onUnavailable: onUnavailable) }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let onCode: (String) -> Void
    private let onUnavailable: () -> Void
    private var done = false

    init(onCode: @escaping (String) -> Void, onUnavailable: @escaping () -> Void) {
        self.onCode = onCode
        self.onUnavailable = onUnavailable
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { onUnavailable(); return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { onUnavailable(); return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.layer.bounds
        view.layer.addSublayer(preview)
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.layer.sublayers?.first { $0 is AVCaptureVideoPreviewLayer }?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.stopRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !done, let text = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        done = true
        session.stopRunning()
        onCode(text)
    }
}
