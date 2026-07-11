# IrbisKVM

Native macOS KVM for a physical server: it displays a server's HDMI output in a
window and sends keyboard, trackpad, and mouse input through a CH9329 USB-HID
bridge. It is intended for BIOS/UEFI setup and local recovery when the server
has no monitor or input devices attached.

> This is a **local** KVM, not a remote-desktop product: both USB devices and
> the server's HDMI cable are connected to the same Mac.

## What is needed

- A Mac running macOS 14 or later.
- An **external UVC HDMI capture card**. The app does not depend on a particular
  vendor or model; actual resolution and frame rate depend on the card and the
  server signal.
- A CH9329 USB-HID bridge controlled over UART, commonly sold as a
  `CH340/CH9329 UART-to-keyboard/mouse` cable or board.
- A server with an HDMI output and a USB port that accepts a standard HID
  keyboard/mouse during boot.

The CH340 USB-UART endpoint is for the Mac. The CH9329 USB-HID endpoint is for
the server. A generic USB-to-UART adapter by itself cannot emulate a keyboard
or mouse.

```text
Mac ── USB ── CH340 / UART ══ CH9329 / HID ── USB ── server
Mac ── USB ── UVC HDMI capture ←── HDMI OUT ──────── server
```

Do not connect a bare TTL UART header directly to a server USB port. Use a
CH9329 bridge or cable made for this topology, verify its pinout and voltage
levels first, and unplug it if the wiring is uncertain.

## Run from Xcode

1. Clone the repository and open `IrbisKVM.xcodeproj` in Xcode.
2. Select the **IrbisKVM** target, open **Signing & Capabilities**, choose your
   Personal Team, and use a bundle identifier that belongs to you.
3. Run the app from Xcode.
4. In the app, select the HDMI capture device, click **«Включить HDMI»**, and
   grant the macOS Camera permission when first asked.
5. Select the UART port and baud rate, then click **«Подключить UART»**. CH9329
   normally uses **9600 baud**; choose 115200 only if the bridge was configured
   for it.
6. Click the video image to capture input. The local cursor is hidden while
   captured, so the server sees the only active cursor. Press `Ctrl`+`Option`+`Esc`
   or **«Отпустить ввод»** to release it.

The first click only captures input; it is intentionally not sent to the
server. The mouse is relative, which is the most reliable mode in BIOS/UEFI.

Use the **«На весь экран»** button or `Ctrl`+`Command`+`F` for fullscreen. Entering
fullscreen releases captured input first, preventing a stuck local cursor.

## Camera permission

The app requests Camera access only while macOS reports that the permission is
undecided. If macOS asks on every run, the OS is seeing a different application
identity, which commonly happens with ad-hoc builds in changing build folders.

Choose a signing team, keep the signed app in a stable location, and run that
same copy. For a distributable public binary, use Developer ID signing and
notarization. IrbisKVM does not store or try to bypass macOS privacy decisions.

## Build and verify from Terminal

```bash
./scripts/verify.sh
```

The script builds without signing and runs a protocol self-test. To use the
Camera permission reliably, run a signed build from Xcode as described above.

## Safe UART diagnostic

`CH9329WireProbe` never chooses a port automatically. Its default request is
`GET_INFO`; `--release-reports` additionally sends empty keyboard and mouse
reports, which is safe only for the selected CH9329 bridge.

```bash
xcrun swiftc -parse-as-library \
  IrbisKVM/Protocol/CH9329Protocol.swift \
  IrbisKVM/Services/CH9329SerialTransport.swift \
  tools/CH9329WireProbe.swift \
  -o /tmp/CH9329WireProbe

/tmp/CH9329WireProbe --port /dev/cu.usbserial-XXXX --baud 9600
```

## Portability and limits

- There are no machine-specific absolute paths, device vendor IDs, or secrets
  in the project. Video devices and UART ports are selected in the UI and the
  choices are remembered locally.
- The app is deliberately CH9329-specific at the protocol layer. Supporting
  Arduino, PiKVM, IPMI/iKVM, or another HID bridge needs a separate transport.
- UVC capture cards that do not expose 1080p60 or 720p60 still work, but use
  their default available mode. The app prefers 1080p60 and then 720p60 to keep
  the preview responsive.
- It does not yet provide server power control, virtual media, audio capture,
  network access, multi-server profiles, or a notarized release binary.

## Project layout

- `IrbisKVM/` — the SwiftUI application.
- `IrbisKVM/Protocol/` — CH9329 frame and HID report encoding.
- `IrbisKVM/Services/` — UART, HDMI capture, and local pointer capture.
- `tools/` — protocol self-test and explicit-port hardware diagnostic.
- `scripts/verify.sh` — unsigned build plus protocol test used by CI.

## License

[MIT](LICENSE) © KaroUniform.
