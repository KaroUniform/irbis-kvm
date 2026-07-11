@preconcurrency import AVFoundation
import Foundation

@MainActor
final class VideoCaptureController: NSObject, ObservableObject {
    @Published private(set) var statusText = "Video is off"
    @Published private(set) var activeFormatText = "—"
    @Published private(set) var isRunning = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var availableDevices: [CaptureDeviceOption] = []
    @Published var selectedDeviceID = ""

    let session = AVCaptureSession()
    let previewLayer: AVCaptureVideoPreviewLayer

    private var videoInput: AVCaptureDeviceInput?
    private let selectedDeviceIDKey = "selectedVideoDeviceID"

    override init() {
        selectedDeviceID = UserDefaults.standard.string(forKey: selectedDeviceIDKey) ?? ""
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspect
        super.init()
        refreshDevices()
    }

    func refreshDevices() {
        let devices = externalVideoDevices()
        availableDevices = devices.map { CaptureDeviceOption(id: $0.uniqueID, name: $0.localizedName) }
        guard !availableDevices.isEmpty else {
            selectedDeviceID = ""
            return
        }
        guard availableDevices.contains(where: { $0.id == selectedDeviceID }) else {
            selectedDeviceID = availableDevices[0].id
            UserDefaults.standard.set(selectedDeviceID, forKey: selectedDeviceIDKey)
            return
        }
    }

    func selectDevice(_ identifier: String) {
        guard identifier != selectedDeviceID else { return }
        let shouldRestart = isRunning
        if shouldRestart { stop() }
        selectedDeviceID = identifier
        UserDefaults.standard.set(identifier, forKey: selectedDeviceIDKey)
        if shouldRestart { start() }
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            statusText = "Waiting for HDMI capture permission…"
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.configureAndStart()
                    } else {
                        self.permissionDenied = true
                        self.statusText = "Camera access is unavailable — enable IrbisKVM in System Settings → Privacy & Security → Camera"
                    }
                }
            }
        case .denied, .restricted:
            permissionDenied = true
            statusText = "Camera access is unavailable — enable IrbisKVM in System Settings → Privacy & Security → Camera"
        @unknown default:
            statusText = "Unknown camera authorization status"
        }
    }

    func stop() {
        guard session.isRunning else { return }
        session.stopRunning()
        isRunning = false
        statusText = "Video stopped"
    }

    private func configureAndStart() {
        guard !session.isRunning else { return }

        refreshDevices()
        let devices = externalVideoDevices()

        guard let device = devices.first(where: { $0.uniqueID == selectedDeviceID }) else {
            statusText = "No UVC HDMI capture device found"
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            do {
                session.inputs.forEach(session.removeInput)
                guard session.canAddInput(input) else {
                    session.commitConfiguration()
                    statusText = "Could not add the HDMI capture device to the session"
                    return
                }
                session.addInput(input)
                try configurePreferredFrameRate(for: device)
                videoInput = input
                session.commitConfiguration()
            } catch {
                session.commitConfiguration()
                throw error
            }
            session.startRunning()
            isRunning = true
            permissionDenied = false
            activeFormatText = describeActiveFormat(for: device)
            statusText = "HDMI: \(device.localizedName) · \(activeFormatText)"
        } catch {
            statusText = "Could not open HDMI capture device: \(error.localizedDescription)"
        }
    }

    private func configurePreferredFrameRate(for device: AVCaptureDevice) throws {
        guard let mode = preferredMode(for: device) else { return }

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = mode.format
        device.activeVideoMinFrameDuration = mode.duration
        device.activeVideoMaxFrameDuration = mode.duration
    }

    private func preferredMode(for device: AVCaptureDevice) -> CaptureMode? {
        // The capture card exposes 1080p60 and 720p60. Prefer full HD, then choose a frame range
        // nearest 60 fps. The range's own duration avoids a rejected hard-coded 1/60 on 60.00024 fps.
        for preferredSize in [(Int32(1920), Int32(1080)), (Int32(1280), Int32(720))] {
            let modes = device.formats.compactMap { format -> CaptureMode? in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard dimensions.width == preferredSize.0, dimensions.height == preferredSize.1 else { return nil }
                guard let range = format.videoSupportedFrameRateRanges
                    .filter({ $0.maxFrameRate >= 59.0 })
                    .min(by: { abs($0.maxFrameRate - 60) < abs($1.maxFrameRate - 60) })
                else { return nil }
                return CaptureMode(format: format, duration: range.minFrameDuration, fps: range.maxFrameRate)
            }
            if let mode = modes.min(by: { abs($0.fps - 60) < abs($1.fps - 60) }) {
                return mode
            }
        }
        return nil
    }

    private func describeActiveFormat(for device: AVCaptureDevice) -> String {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let minDuration = device.activeVideoMinFrameDuration
        let maxDuration = device.activeVideoMaxFrameDuration
        let maximumFPS = minDuration.seconds > 0 ? 1 / minDuration.seconds : 0
        let minimumFPS = maxDuration.seconds > 0 ? 1 / maxDuration.seconds : 0
        if abs(maximumFPS - minimumFPS) < 0.1 {
            return String(format: "%d×%d · %.0f fps", dimensions.width, dimensions.height, maximumFPS)
        }
        return String(format: "%d×%d · %.0f–%.0f fps", dimensions.width, dimensions.height, minimumFPS, maximumFPS)
    }

    private func externalVideoDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        ).devices
    }
}

private struct CaptureMode {
    let format: AVCaptureDevice.Format
    let duration: CMTime
    let fps: Double
}

struct CaptureDeviceOption: Identifiable, Equatable {
    let id: String
    let name: String
}
