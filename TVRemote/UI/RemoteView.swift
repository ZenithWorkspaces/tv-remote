import SwiftUI
import UIKit

enum Haptics {
    private static let impact = UIImpactFeedbackGenerator(style: .light)

    static func prepare() {
        impact.prepare()
    }

    static func tap() {
        impact.impactOccurred(intensity: 0.65)
        impact.prepare()
    }
}

extension Color {
    static let remoteBackground = Color(red: 0.043, green: 0.047, blue: 0.063)
    static let remoteRaised = Color(red: 0.11, green: 0.12, blue: 0.15)
    static let remoteButton = Color(red: 0.16, green: 0.175, blue: 0.22)
    static let remoteAccent = Color(red: 0.486, green: 0.549, blue: 1.0)
    static let remoteDanger = Color(red: 0.89, green: 0.36, blue: 0.31)
    static let remoteWarning = Color(red: 0.93, green: 0.72, blue: 0.32)
    static let remoteOK = Color(red: 0.45, green: 0.78, blue: 0.52)
}

struct RemoteView: View {
    @Bindable var session: RemoteSession

    var body: some View {
        ZStack {
            Color.remoteBackground.ignoresSafeArea()
            if session.devices.isEmpty {
                emptyState
            } else {
                controls
            }
        }
        .sheet(isPresented: $session.showManualAdd) {
            ManualAddSheet(session: session)
        }
        .sheet(isPresented: $session.showKeyboard) {
            KeyboardSheet(session: session)
        }
        .sheet(isPresented: $session.showInputs) {
            InputSheet(session: session)
        }
        .sheet(item: $session.pairing) { request in
            PairingSheet(session: session, request: request)
        }
        .confirmationDialog("Forget this TV?", isPresented: $session.confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { session.forgetActive() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved pairing keys for this TV are removed from this phone.")
        }
        .onAppear { Haptics.prepare() }
    }

    private var controls: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                statusLine
                switcher
                if session.activeDevice?.brand.support == .planned {
                    plannedCard
                } else {
                    shortcuts
                    padCluster
                    transport
                    systemRow
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 18)
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.activeDevice?.name ?? "No Ads Remote")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let brand = session.activeDevice?.brand {
                        Text(brand.displayName)
                        if brand.support == .beta {
                            Text("Beta")
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.remoteWarning.opacity(0.2), in: Capsule())
                                .foregroundStyle(Color.remoteWarning)
                        }
                    } else {
                        Text("No TV selected")
                    }
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
            }
            Spacer(minLength: 8)
            Menu {
                Button("Scan Wi-Fi") { session.rescan() }
                Button("Add by IP") { session.showManualAdd = true }
                if session.activeDevice != nil {
                    Button("Forget this TV", role: .destructive) { session.confirmForget = true }
                }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 48, height: 48)
            }
            .accessibilityLabel("More")
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(session.isScanning && session.linkState == .connected ? "Connected · scanning" : session.statusText)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.86))
                .frame(maxWidth: .infinity, alignment: .leading)
            if session.linkState == .notFound || session.linkState == .lost {
                Button("Retry") { session.retry() }
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.remoteAccent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(statusColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch session.linkState {
        case .connected: return .remoteOK
        case .connecting, .pairing, .reconnecting, .idle: return .remoteWarning
        case .notFound, .lost, .unavailable: return .remoteDanger
        }
    }

    private var switcher: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(session.devices) { device in
                    Button {
                        session.select(device)
                    } label: {
                        HStack(spacing: 6) {
                            Text(device.name)
                                .lineLimit(1)
                            if device.brand.support == .beta {
                                Text("Beta")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.remoteWarning)
                            }
                        }
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(device.id == session.activeID ? Color.black : Color.white)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background(device.id == session.activeID ? Color.white : Color.remoteButton, in: Capsule())
                    }
                    .accessibilityLabel("Switch to \(device.name)")
                    .accessibilityAddTraits(device.id == session.activeID ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private var shortcuts: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(AppShortcut.all) { shortcut in
                    Button {
                        session.launch(shortcut)
                    } label: {
                        Text(shortcut.title)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 48)
                            .background(Color.remoteButton, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .accessibilityLabel("Launch \(shortcut.title)")
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var padCluster: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(spacing: 8) {
                padKey("VOL +", systemImage: "speaker.plus.fill", key: .volumeUp)
                padKey("MUTE", systemImage: "speaker.slash.fill", key: .mute)
                padKey("VOL −", systemImage: "speaker.minus.fill", key: .volumeDown)
            }
            .frame(width: 76)
            Group {
                if session.swipeMode {
                    swipePad
                } else {
                    dPad
                }
            }
            .frame(maxWidth: .infinity)
            VStack(spacing: 8) {
                padKey("CH +", systemImage: "chevron.up", key: .channelUp)
                padKey("PLAY", systemImage: "playpause.fill", key: .playPause)
                padKey("CH −", systemImage: "chevron.down", key: .channelDown)
            }
            .frame(width: 76)
        }
    }

    private var dPad: some View {
        VStack(spacing: 8) {
            arrow(.up, image: "chevron.up")
            HStack(spacing: 8) {
                arrow(.left, image: "chevron.left")
                Button {
                    session.press(.ok)
                } label: {
                    Text("OK")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 72)
                        .background(Color.remoteAccent.opacity(0.9), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .accessibilityLabel("OK")
                arrow(.right, image: "chevron.right")
            }
            arrow(.down, image: "chevron.down")
            Button(session.swipeMode ? "Buttons" : "Swipe pad") {
                session.swipeMode.toggle()
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.7))
            .frame(minHeight: 32)
        }
    }

    private var swipePad: some View {
        VStack(spacing: 8) {
            SwipePad { key in
                session.press(key)
            }
            .frame(height: 196)
            Button("Buttons") { session.swipeMode = false }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .frame(minHeight: 32)
        }
    }

    private var transport: some View {
        HStack(spacing: 8) {
            wideKey("Rewind", systemImage: "backward.fill", key: .rewind)
            wideKey("Forward", systemImage: "forward.fill", key: .fastForward)
        }
    }

    private var systemRow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                symbolKey("Power", systemImage: "power", tint: .remoteDanger) { session.power() }
                symbolKey("Input", systemImage: "rectangle.connected.to.line.below") { session.openInputs() }
                symbolKey("Home", systemImage: "house.fill", key: .home)
                symbolKey("Back", systemImage: "arrow.uturn.backward", key: .back)
            }
            HStack(spacing: 8) {
                symbolKey("Menu", systemImage: "gearshape.fill", key: .menu)
                symbolKey("Keyboard", systemImage: "keyboard") { session.openKeyboard() }
            }
        }
    }

    private var plannedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.activeDevice?.brand.displayName ?? "This TV")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text(session.statusText)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
            Text("Roku and LG are ready. Samsung, Sony, and Vizio are beta. Android TV and Fire TV are saved only.")
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.remoteRaised, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .foregroundStyle(.white)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tv")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(Color.remoteAccent)
            Text("No Ads Remote")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(session.isScanning ? "Looking on this Wi-Fi…" : "No TV yet. Scan the network or add one by IP address.")
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button("Scan Wi-Fi") { session.rescan() }
                .buttonStyle(RemoteFillStyle(tint: .remoteAccent))
            Button("Add by IP") { session.showManualAdd = true }
                .buttonStyle(RemoteFillStyle(tint: .remoteButton))
        }
        .padding(24)
    }

    private func padKey(_ title: String, systemImage: String, key: RemoteKey) -> some View {
        Button {
            session.press(key)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .bold))
                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(Color.remoteButton, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .accessibilityLabel(title)
    }

    private func arrow(_ key: RemoteKey, image: String) -> some View {
        Button {
            session.press(key)
        } label: {
            Image(systemName: image)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Color.remoteButton, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .accessibilityLabel(Text(directionName(key)))
    }

    private func wideKey(_ title: String, systemImage: String, key: RemoteKey) -> some View {
        Button {
            session.press(key)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Color.remoteButton, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .accessibilityLabel(title)
    }

    private func symbolKey(_ title: String, systemImage: String, tint: Color = .remoteButton, key: RemoteKey? = nil, action: (() -> Void)? = nil) -> some View {
        Button {
            if let action {
                action()
            } else if let key {
                session.press(key)
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(tint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .accessibilityLabel(title)
    }

    private func directionName(_ key: RemoteKey) -> String {
        switch key {
        case .up: return "Up"
        case .down: return "Down"
        case .left: return "Left"
        case .right: return "Right"
        default: return "Direction"
        }
    }
}

private struct SwipePad: View {
    var onKey: (RemoteKey) -> Void
    @State private var sent = false

    var body: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(Color.remoteRaised)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "hand.draw")
                        .font(.system(size: 28, weight: .semibold))
                    Text("Swipe to move")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("Tap for OK")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .foregroundStyle(.white)
            }
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !sent else { return }
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard abs(dx) > 28 || abs(dy) > 28 else { return }
                        sent = true
                        if abs(dx) > abs(dy) {
                            onKey(dx > 0 ? .right : .left)
                        } else {
                            onKey(dy > 0 ? .down : .up)
                        }
                    }
                    .onEnded { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        if !sent && abs(dx) < 18 && abs(dy) < 18 {
                            onKey(.ok)
                        }
                        sent = false
                    }
            )
            .accessibilityLabel("Swipe pad")
            .accessibilityHint("Swipe up, down, left, or right. Tap for OK.")
    }
}

private struct RemoteFillStyle: ButtonStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: 280, minHeight: 56)
            .background(tint.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ManualAddSheet: View {
    var session: RemoteSession
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var name = ""
    @State private var brandChoice = "Auto"
    @State private var error = ""
    @State private var saving = false

    private let choices = ["Auto"] + TVBrand.allCases.map(\.displayName)

    var body: some View {
        NavigationStack {
            Form {
                Section("TV") {
                    TextField("IP address", text: $host)
                        .keyboardType(.decimalPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Name (optional)", text: $name)
                    Picker("Brand", selection: $brandChoice) {
                        ForEach(choices, id: \.self) { choice in
                            Text(choice).tag(choice)
                        }
                    }
                }
                if !error.isEmpty {
                    Section {
                        Text(error)
                            .foregroundStyle(Color.remoteDanger)
                    }
                }
            }
            .navigationTitle("Add TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Adding…" : "Add") { add() }
                        .disabled(saving || host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func add() {
        saving = true
        error = ""
        let selected = TVBrand.allCases.first { $0.displayName == brandChoice }
        Task {
            let message = await session.addManual(host: host, name: name, brand: selected)
            saving = false
            if let message {
                error = message
            } else {
                dismiss()
            }
        }
    }
}

private struct KeyboardSheet: View {
    var session: RemoteSession
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Text is sent to the screen that's open on the TV. Put the cursor in a text field first.")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                TextField("Type here", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    Button("Backspace") { session.deleteBackward() }
                        .buttonStyle(RemoteFillStyle(tint: .remoteButton))
                    Button("Send") {
                        session.sendKeyboardText(text)
                        text = ""
                    }
                    .buttonStyle(RemoteFillStyle(tint: .remoteAccent))
                }
                Spacer()
            }
            .padding(20)
            .background(Color.remoteBackground.ignoresSafeArea())
            .navigationTitle("Keyboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct InputSheet: View {
    var session: RemoteSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if session.inputs.isEmpty {
                    Text("No inputs reported yet.")
                } else {
                    ForEach(session.inputs) { input in
                        Button(input.name) {
                            session.select(input: input)
                            dismiss()
                        }
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    }
                }
            }
            .navigationTitle("Input")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct PairingSheet: View {
    @Bindable var session: RemoteSession
    var request: PairingRequest
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text(message)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                if needsEntry {
                    SecureField(entryTitle, text: $session.pairingDraft)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(isPIN ? .numberPad : .asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Continue") {
                        session.submitPairing()
                    }
                    .buttonStyle(RemoteFillStyle(tint: .remoteAccent))
                }
                Spacer()
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.remoteBackground.ignoresSafeArea())
            .navigationTitle("Pair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        session.cancelPairing()
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }

    private var isPIN: Bool {
        if case .pin(_) = request.kind { return true }
        return false
    }

    private var needsEntry: Bool {
        switch request.kind {
        case .pin(_), .psk(_): return true
        case .acceptOnTV(_): return false
        }
    }

    private var entryTitle: String {
        switch request.kind {
        case .pin(_): return "PIN"
        case .psk(_): return "Pre-shared key"
        case .acceptOnTV(_): return ""
        }
    }

    private var message: String {
        switch request.kind {
        case .acceptOnTV(_): return "Allow the remote on the TV"
        case .pin(_): return "Enter the PIN"
        case .psk(_): return "Enter the pre-shared key"
        }
    }

    private var detail: String {
        switch request.kind {
        case let .acceptOnTV(text), let .pin(text), let .psk(text):
            return text
        }
    }
}
