import AppKit
import SwiftUI

struct KVMContentView: View {
    @ObservedObject var controller: KVMController

    var body: some View {
        VStack(spacing: 14) {
            header

            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black)

                VideoPreviewView(previewLayer: controller.video.previewLayer)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                InputCaptureView(controller: controller)

                if !controller.video.isRunning {
                    videoPlaceholder
                }

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        captureHint
                    }
                }
                .padding(14)
            }
            .frame(minWidth: 900, minHeight: 560)

            controls
            statusBar
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            controller.refreshSerialPorts()
            controller.video.refreshDevices()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("IrbisKVM")
                    .font(.title2.weight(.semibold))
                Text("Local console for physical servers")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(controller.video.isRunning ? "Stop HDMI Capture" : "Start HDMI Capture") {
                if controller.video.isRunning {
                    controller.video.stop()
                } else {
                    controller.video.start()
                }
            }
            .buttonStyle(.borderedProminent)
            Button {
                controller.releaseInput()
                (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
            } label: {
                Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help("Full Screen (⌃⌘F)")
        }
    }

    private var videoPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.inset.filled.and.camera")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text(controller.video.statusText)
                .foregroundStyle(.secondary)
            if controller.video.permissionDenied {
                Text("System Settings → Privacy & Security → Camera")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var captureHint: some View {
        Text(controller.inputCaptured ? "Input captured · local pointer hidden · ⌃⌥Esc releases" : "Click the video to capture input")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.6), in: Capsule())
            .foregroundStyle(.white)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if controller.inputCaptured {
                    Button("Release Input") { controller.releaseInput() }
                } else {
                    Text("Click the video to send input")
                        .foregroundStyle(.secondary)
                }

                Divider().frame(height: 22)
                keyButton("Esc", usage: 0x29)
                keyButton("Del", usage: 0x4C)
                keyButton("F1", usage: 0x3A)
                keyButton("F2", usage: 0x3B)
                keyButton("F10", usage: 0x43)
                keyButton("F11", usage: 0x44)
                keyButton("F12", usage: 0x45)
                Button("Ctrl Alt Del") { controller.sendControlAltDelete() }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Picker("Video Capture", selection: Binding(
                    get: { controller.video.selectedDeviceID },
                    set: { controller.video.selectDevice($0) }
                )) {
                    Text("Select a video capture device").tag("")
                    ForEach(controller.video.availableDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .frame(width: 210)
                Button("↻") { controller.video.refreshDevices() }
                    .help("Refresh video devices")

                Divider().frame(height: 22)

                Picker("UART", selection: Binding(
                    get: { controller.selectedSerialPort },
                    set: { controller.selectSerialPort($0) }
                )) {
                    Text("Select a UART port").tag("")
                    ForEach(controller.availableSerialPorts, id: \.self) { port in
                        Text(port.replacingOccurrences(of: "/dev/", with: "")).tag(port)
                    }
                }
                .frame(width: 240)
                Button("↻") { controller.refreshSerialPorts() }
                    .help("Refresh UART ports")
                Picker("Baud Rate", selection: Binding(
                    get: { controller.selectedSerialBaud },
                    set: { controller.selectSerialBaud($0) }
                )) {
                    ForEach(SerialBaud.allCases) { baud in
                        Text("\(baud.rawValue) baud").tag(baud)
                    }
                }
                .frame(width: 115)
                Button("Connect UART") { controller.connectSerial() }
                Button("Disconnect") { controller.disconnectSerial() }
                    .disabled(controller.serialStatus == .idle)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlSize(.small)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            StatusPill(
                title: "HDMI",
                detail: controller.video.statusText,
                status: controller.video.isRunning ? .ready : .idle
            )
            StatusPill(
                title: "UART",
                detail: controller.serialMessage,
                status: controller.serialStatus
            )
            Spacer()
            Text("Input is sent only while this window is active")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func keyButton(_ title: String, usage: UInt8) -> some View {
        Button(title) { controller.tapKey(usage) }
    }
}

private struct StatusPill: View {
    let title: String
    let detail: String
    let status: ConnectionStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.quaternary, in: Capsule())
    }

    private var color: Color {
        switch status {
        case .idle: return .secondary
        case .connecting: return .orange
        case .ready: return .green
        case .warning: return .yellow
        case .failed: return .red
        }
    }
}
