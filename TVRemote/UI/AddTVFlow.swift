import SwiftUI

struct AddTVSheet: View {
    @Bindable var session: RemoteSession
    @Environment(\.dismiss) private var dismiss
    @State private var setup: TVDevice?

    var body: some View {
        NavigationStack {
            Group {
                if !session.isScanning && session.discovered.isEmpty {
                    emptyScan
                } else {
                    List {
                        if session.isScanning {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Looking for TVs on your Wi-Fi…")
                                    .font(.system(size: 16, weight: .medium))
                            }
                            .listRowBackground(Color.clear)
                        }
                        ForEach(session.discovered) { device in
                            foundRow(device)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.remoteBackground)
            .navigationTitle("Add TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(item: $setup) { device in
                TVSetupView(session: session, device: device)
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .onAppear { session.prepareAddScan() }
    }

    private var emptyScan: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "tv")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.white.opacity(0.85))
            Text(AddTVCopy.empty)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
            Button("Scan again") {
                Haptics.lightTap()
                session.prepareAddScan()
            }
            .buttonStyle(RemoteFillStyle(tint: .remoteAccent))
            Spacer()
        }
        .padding(28)
    }

    private func foundRow(_ device: TVDevice) -> some View {
        let saved = session.devices.contains { $0.id == device.id }
        return Button {
            Haptics.lightTap()
            if saved, let existing = session.devices.first(where: { $0.id == device.id }) {
                session.select(existing)
                dismiss()
            } else {
                setup = device
            }
        } label: {
            HStack(spacing: 12) {
                Text(device.brand.badgeName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(badgeColor(device.brand), in: Capsule())
                VStack(alignment: .leading, spacing: 2) {
                    Text(TVDisplayName.suggestion(brand: device.brand, discovered: device.name))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(device.host)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                if saved {
                    Text("Added")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.12), in: Capsule())
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.white.opacity(0.06))
    }

    private func badgeColor(_ brand: TVBrand) -> Color {
        let rgb = brand.badgeColor
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

private struct TVSetupView: View {
    @Bindable var session: RemoteSession
    var device: TVDevice
    @State private var name = ""
    @State private var samsungShowsPIN = false
    @State private var connecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Name")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            HStack {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                if !name.isEmpty {
                    Button {
                        name = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .accessibilityLabel("Clear name")
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                    .foregroundStyle(Color.remoteAccent)
                Text(AddTVCopy.instruction(brand: device.brand, samsungShowsPIN: samsungShowsPIN))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if let error = session.addSetupError, !error.isEmpty {
                Text(error)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.remoteDanger)
                Button("Try again") { connect() }
                    .buttonStyle(RemoteFillStyle(tint: .remoteAccent))
            }

            Spacer()
            Button(connecting ? "Connecting…" : "Connect") { connect() }
                .buttonStyle(RemoteFillStyle(tint: .remoteAccent))
                .disabled(connecting || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .frame(maxWidth: .infinity)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.remoteBackground)
        .navigationTitle("Set up \(TVDisplayName.suggestion(brand: device.brand, discovered: device.name))")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if name.isEmpty {
                name = TVDisplayName.suggestion(brand: device.brand, discovered: device.name)
            }
        }
        .onChange(of: session.addSetupError) { _, error in
            if error != nil { connecting = false }
        }
        .onChange(of: session.linkState) { _, state in
            if state == .pairing || state == .connected || state == .notFound || state == .lost {
                connecting = false
            }
        }
        .task {
            guard device.brand == .samsung else { return }
            async let modern = TCPProbe.isOpen(host: device.host, port: 8001, timeout: 1.2)
            async let older = TCPProbe.isOpen(host: device.host, port: UInt16(SamsungEncrypted.pairingPort), timeout: 1.2)
            let (hasModern, hasOlder) = await (modern, older)
            samsungShowsPIN = hasOlder && !hasModern
        }
        .sheet(item: $session.pairing) { request in
            PairingSheet(session: session, request: request)
        }
    }

    private func connect() {
        Haptics.lightTap()
        connecting = true
        session.addSetupError = nil
        session.connectFound(device, name: name)
    }
}

struct AdvancedSheet: View {
    var session: RemoteSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                NavigationLink("Add by IP address") {
                    ManualAddSheet(session: session, embedded: true)
                }
            }
            .navigationTitle("Advanced")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
    }
}
