import SwiftUI
import AVFoundation
import Vision

/// SwiftUI wrapper around an AVFoundation camera + Vision barcode scanner.
/// Emits detected ISBN/EAN codes via `onCode`.
struct ISBNScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void
    var rescanKey: Int = 0

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> BarcodeScannerViewController {
        let vc = BarcodeScannerViewController()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_ uiViewController: BarcodeScannerViewController, context: Context) {
        if context.coordinator.lastRescanKey != rescanKey {
            uiViewController.reset()
        }
        context.coordinator.lastRescanKey = rescanKey
        uiViewController.onCode = onCode
    }

    static func dismantleUIViewController(_ uiViewController: BarcodeScannerViewController, coordinator: Coordinator) {
        uiViewController.stop()
    }

    final class Coordinator {
        var lastRescanKey = 0
    }
}

final class BarcodeScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didDetect = false

    override func viewDidLoad() {
        super.viewDidLoad()
        setupCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stop()
    }

    func stop() {
        if captureSession?.isRunning == true {
            captureSession?.stopRunning()
        }
    }

    func reset() {
        didDetect = false
        if captureSession?.isRunning != true {
            captureSession?.startRunning()
        }
    }

    private func setupCamera() {
        let session = AVCaptureSession()
        session.sessionPreset = .high
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: AVMediaType.video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        output.metadataObjectTypes = [.ean13, .upce, .ean8, .code39]

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        self.previewLayer = previewLayer

        session.startRunning()
        self.captureSession = session
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !didDetect else { return }
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let code = object.stringValue else { return }
        didDetect = true
        onCode?(code)
    }
}
