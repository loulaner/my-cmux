import AppKit
import CmuxMobileTransport
import SwiftUI

/// Existing pairing surfaces share this opt-in local host UI and its single controller.
struct MobileLocalDirectView: View {
    @State private var controller: MobileLocalDirectHostController
    @State private var address = ""
    @State private var port = "49443"
    @State private var enabled = false
    @State private var viewID = UUID()

    /// Uses the app owner by default; isolated hosts can supply their own persisted configuration.
    init(controller: MobileLocalDirectHostController = .shared) {
        _controller = State(initialValue: controller)
        _address = State(initialValue: controller.configuration?.address ?? "")
        _port = State(initialValue: String(controller.configuration?.port ?? 49443))
        _enabled = State(initialValue: controller.configuration?.enabled ?? false)
    }

    private var validAddress: Bool {
        guard let value = Int(port) else { return false }
        return (try? CmxLocalTCPListenerConfiguration(address: address, port: value)) != nil
    }
    private var listening: Bool { if case .listening = controller.state { return true }; return false }
    private var status: String {
        switch controller.state {
        case .stopped: return String(localized: "mobile.direct.off", defaultValue: "Off")
        case .starting: return String(localized: "mobile.direct.starting", defaultValue: "Starting")
        case .listening: return String(localized: "mobile.direct.listening", defaultValue: "Listening")
        case .failed: return String(localized: "mobile.direct.failed", defaultValue: "Unavailable")
        }
    }
    var body: some View {
        Form {
            Section {
                Text(String(localized: "mobile.direct.title", defaultValue: "iPad Direct Connection")).font(.title2)
                Text(String(localized: "mobile.direct.network", defaultValue: "Connect your Mac and iPad to the same Tailscale network."))
                TextField(String(localized: "mobile.direct.address", defaultValue: "Tailscale IPv4 address"), text: $address)
                TextField(String(localized: "mobile.direct.port", defaultValue: "TCP port"), text: $port)
                Toggle(String(localized: "mobile.direct.enable", defaultValue: "Enable direct connections"), isOn: $enabled)
                    .disabled(!validAddress || controller.busy)
                if !validAddress {
                    Text(String(localized: "mobile.direct.validAddress", defaultValue: "Enter a valid Tailscale IPv4 address and port to enable connections."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(String(localized: "mobile.direct.apply", defaultValue: "Apply")) {
                        Task { await controller.apply(address: address, port: port, enabled: enabled && validAddress) }
                    }.disabled(controller.busy || (!address.isEmpty && !validAddress))
                    Text(status).accessibilityIdentifier("LocalDirectStatus")
                    if controller.state == .failed {
                        Button(String(localized: "mobile.direct.retry", defaultValue: "Retry")) { Task { await controller.retry() } }
                            .disabled(controller.busy)
                    }
                }
                Button(String(localized: "mobile.direct.copy", defaultValue: "Copy connection address")) {
                    guard case let .listening(host, port) = controller.state else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(host):\(port)", forType: .string)
                }.disabled(!listening)
                if controller.hasError {
                    Text(String(localized: "mobile.direct.error", defaultValue: "Could not complete this operation. Check the settings and VPN connection, then retry."))
                        .foregroundStyle(.red)
                }
            }
            Section {
                Toggle(String(localized: "mobile.direct.pairing", defaultValue: "Allow new devices for 60 seconds"),
                    isOn: Binding(get: { controller.allowsPairing }, set: {
                        if $0 { controller.openPairingWindow() } else { controller.closePairingWindow() }
                    })).disabled(!listening)
                if let name = controller.pendingApproval {
                    Text(String(localized: "mobile.direct.selfReported", defaultValue: "Device-reported name (not verified):"))
                    Text(verbatim: name).textSelection(.enabled)
                    HStack {
                        Button(String(localized: "mobile.direct.deny", defaultValue: "Deny")) { controller.resolveApproval(false) }
                        Button(String(localized: "mobile.direct.allow", defaultValue: "Allow")) { controller.resolveApproval(true) }
                    }
                }
            }
            Section(String(localized: "mobile.direct.devices", defaultValue: "Approved devices")) {
                ForEach(controller.devices, id: \.deviceID) { device in
                    HStack {
                        Text(verbatim: device.displayName)
                        Spacer()
                        Button(String(localized: "mobile.direct.remove", defaultValue: "Remove"), role: .destructive) {
                            Task { await controller.removeDevice(device.deviceID) }
                        }.disabled(controller.busy)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            controller.viewOpened(viewID)
            await controller.load()
            if let config = controller.configuration {
                address = config.address ?? ""; port = String(config.port); enabled = config.enabled
            }
        }
        .onChange(of: controller.configuration) { _, config in
            if let config { address = config.address ?? ""; port = String(config.port); enabled = config.enabled }
        }
        .onDisappear { controller.viewClosed(viewID) }
    }
}
