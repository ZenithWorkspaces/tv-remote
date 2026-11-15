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
    @State private var editingShortcuts = false

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
        .sheet(isPresented: $session.showRename, onDismiss: { session.dismissRename() }) {
            RenameSheet(session: session)
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
        VStack(spacing: 8) {
            header
            if session.linkState == .notFound || session.linkState == .lost {
                statusLine
            }
            startingRow
            menuKeyboardRow
            shortcuts
            DirectionPad { session.press($0) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            volumeChannelRow
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                if session.needsReconnect { session.retry() }
            } label: {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
            }
            .disabled(!session.needsReconnect)
            .accessibilityLabel(statusAccessibility)

            Group {
                if session.needsReconnect {
                    Button(action: session.retry) { nameLabel }
                } else {
                    Menu { televisionMenu } label: { nameLabel }
                }
            }
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                session.beginRename()
            })

            Spacer(minLength: 8)
            Menu {
                televisionMenu
                Button("Scan Wi-Fi") { session.rescan() }
                if session.activeDevice != nil {
                    Button("Forget this TV", role: .destructive) { session.confirmForget = true }
                }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("More")
        }
        .frame(minHeight: 44)
    }

    private var nameLabel: some View {
        Text(session.activeDevice.map { session.displayName(for: $0) } ?? "No Ads Remote")
            .font(.system(size: 22, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
    }

    @ViewBuilder
    private var televisionMenu: some View {
        ForEach(session.devices) { device in
            Button {
                session.select(device)
            } label: {
                if device.id == session.activeID {
                    Label(session.displayName(for: device), systemImage: "checkmark")
                } else {
                    Text(session.displayName(for: device))
                }
            }
        }
        if !session.devices.isEmpty { Divider() }
        Button("Rename") { session.beginRename() }
        Button("Add TV") { session.showManualAdd = true }
    }

    private var startingRow: some View {
        HStack(spacing: 8) {
            symbolKey("Power", systemImage: "power", tint: .remoteDanger) { session.power() }
            symbolKey("Home", systemImage: "house.fill", key: .home)
            symbolKey("Input", systemImage: "rectangle.connected.to.line.below") { session.openInputs() }
            symbolKey("Back", systemImage: "arrow.uturn.backward", key: .back)
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

    private var statusAccessibility: String {
        if session.needsReconnect { return "Reconnect" }
        switch session.linkState {
        case .connected: return "Connected"
        case .connecting, .reconnecting: return "Connecting"
        case .pairing: return "Pairing"
        case .idle: return "No TV"
        case .notFound, .lost, .unavailable: return "Disconnected"
        }
    }

    private var statusColor: Color {
        switch session.linkState {
        case .connected: return .remoteOK
        case .connecting, .pairing, .reconnecting, .idle: return .remoteWarning
        case .notFound, .lost, .unavailable: return .remoteDanger
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 6) {
            if editingShortcuts {
                HStack {
                    Text("Drag to rearrange")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Button("Done") { editingShortcuts = false }
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(session.visibleShortcuts.enumerated()), id: \.element.id) { index, shortcut in
                        shortcutTile(shortcut, index: index)
                    }
                }
            }
            .scrollIndicators(.hidden)
            if editingShortcuts, !session.hiddenShortcuts.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(session.hiddenShortcuts) { shortcut in
                            Button("Show \(shortcut.title)") {
                                session.setShortcut(shortcut.slug, hidden: false)
                            }
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 10)
                            .frame(minHeight: 32)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func shortcutTile(_ shortcut: AppShortcut, index: Int) -> some View {
        let style = ShortcutStyle.style(for: shortcut.slug)
        return VStack(spacing: 4) {
            Text(style.word)
                .font(.system(size: style.word.count > 9 ? 12 : 14, weight: .heavy, design: .rounded))
                .foregroundStyle(style.foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 10)
                .frame(minWidth: 72, minHeight: 44)
                .background(style.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .rotationEffect(.degrees(editingShortcuts ? (index.isMultiple(of: 2) ? -2 : 2) : 0))
                .animation(editingShortcuts ? .easeInOut(duration: 0.14).repeatForever(autoreverses: true) : .default, value: editingShortcuts)
            if editingShortcuts {
                Button("Hide") { session.setShortcut(shortcut.slug, hidden: true) }
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcut.title)
        .accessibilityAddTraits(.isButton)
        .onTapGesture {
            if !editingShortcuts { session.launch(shortcut) }
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            editingShortcuts = true
        }
        .modifier(ShortcutDrag(enabled: editingShortcuts, slug: shortcut.slug) { source in
            session.moveShortcut(source, before: shortcut.slug)
        })
    }

    private var menuKeyboardRow: some View {
        HStack(spacing: 8) {
            symbolKey("Menu", systemImage: "gearshape.fill", key: .menu)
            symbolKey("Keyboard", systemImage: "keyboard") { session.openKeyboard() }
        }
    }

    private var volumeChannelRow: some View {
        HStack(spacing: 8) {
            rocker(
                lowerTitle: "Vol −", lowerImage: "speaker.minus.fill", lower: .volumeDown,
                upperTitle: "Vol +", upperImage: "speaker.plus.fill", upper: .volumeUp
            )
            symbolKey("Mute", systemImage: "speaker.slash.fill", key: .mute)
            symbolKey("Play", systemImage: "playpause.fill", key: .playPause)
            rocker(
                lowerTitle: "Ch −", lowerImage: "chevron.down", lower: .channelDown,
                upperTitle: "Ch +", upperImage: "chevron.up", upper: .channelUp
            )
        }
    }

    private func rocker(
        lowerTitle: String,
        lowerImage: String,
        lower: RemoteKey,
        upperTitle: String,
        upperImage: String,
        upper: RemoteKey
    ) -> some View {
        HStack(spacing: 0) {
            rockerHalf(lowerTitle, systemImage: lowerImage, key: lower)
            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(width: 1, height: 28)
            rockerHalf(upperTitle, systemImage: upperImage, key: upper)
        }
        .frame(maxWidth: .infinity, minHeight: 46)
        .background(Color.remoteButton, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func rockerHalf(_ title: String, systemImage: String, key: RemoteKey) -> some View {
        Button {
            session.press(key)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 46)
        }
        .accessibilityLabel(title)
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
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(tint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .accessibilityLabel(title)
    }

}

private struct DirectionPad: View {
    var onPress: (RemoteKey) -> Void
    @State private var held: RemoteKey?
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.remoteButton)
                Image(systemName: "chevron.up")
                    .position(x: size.width / 2, y: size.height * 0.14)
                Image(systemName: "chevron.down")
                    .position(x: size.width / 2, y: size.height * 0.86)
                Image(systemName: "chevron.left")
                    .position(x: size.width * 0.12, y: size.height / 2)
                Image(systemName: "chevron.right")
                    .position(x: size.width * 0.88, y: size.height / 2)
                Circle()
                    .fill(held == .ok ? Color.remoteAccent.opacity(0.75) : Color.remoteAccent)
                    .frame(width: okDiameter(size), height: okDiameter(size))
                    .overlay {
                        Text("OK")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
            }
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(.white.opacity(0.9))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let next = key(at: value.location, in: size)
                        guard next != held else { return }
                        startHold(next)
                    }
                    .onEnded { _ in
                        stopHold()
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Direction pad")
            .accessibilityAction(named: "Up") { onPress(.up) }
            .accessibilityAction(named: "Down") { onPress(.down) }
            .accessibilityAction(named: "Left") { onPress(.left) }
            .accessibilityAction(named: "Right") { onPress(.right) }
            .accessibilityAction(named: "OK") { onPress(.ok) }
            .onDisappear { stopHold() }
        }
    }

    private func okDiameter(_ size: CGSize) -> CGFloat {
        min(size.width, size.height) * 0.42
    }

    private func key(at point: CGPoint, in size: CGSize) -> RemoteKey {
        let dx = point.x - size.width / 2
        let dy = point.y - size.height / 2
        if hypot(dx, dy) <= okDiameter(size) / 2 {
            return .ok
        }
        if abs(dx) > abs(dy) {
            return dx >= 0 ? .right : .left
        }
        return dy >= 0 ? .down : .up
    }

    private func startHold(_ key: RemoteKey) {
        stopHold()
        held = key
        onPress(key)
        guard key != .ok else { return }
        repeatTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            while !Task.isCancelled {
                onPress(key)
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    private func stopHold() {
        repeatTask?.cancel()
        repeatTask = nil
        held = nil
    }
}

private struct ShortcutStyle {
    var word: String
    var background: Color
    var foreground: Color

    static func style(for slug: String) -> ShortcutStyle {
        switch slug {
        case "netflix":
            return ShortcutStyle(word: "Netflix", background: Color(red: 0.08, green: 0.08, blue: 0.08), foreground: Color(red: 0.90, green: 0.04, blue: 0.08))
        case "prime":
            return ShortcutStyle(word: "prime", background: Color(red: 0.00, green: 0.66, blue: 0.88), foreground: .white)
        case "disney":
            return ShortcutStyle(word: "Disney+", background: Color(red: 0.07, green: 0.16, blue: 0.45), foreground: .white)
        case "youtube":
            return ShortcutStyle(word: "YouTube", background: Color(red: 0.90, green: 0.04, blue: 0.05), foreground: .white)
        case "youtube-tv":
            return ShortcutStyle(word: "YouTube TV", background: Color(red: 0.45, green: 0.02, blue: 0.04), foreground: .white)
        case "max":
            return ShortcutStyle(word: "Max", background: Color(red: 0.00, green: 0.17, blue: 0.91), foreground: .white)
        case "hulu":
            return ShortcutStyle(word: "hulu", background: Color(red: 0.11, green: 0.91, blue: 0.51), foreground: .black)
        case "peacock":
            return ShortcutStyle(word: "Peacock", background: Color(red: 0.06, green: 0.06, blue: 0.09), foreground: Color(red: 0.86, green: 0.73, blue: 0.36))
        case "paramount":
            return ShortcutStyle(word: "Paramount+", background: Color(red: 0.00, green: 0.39, blue: 1.0), foreground: .white)
        case "apple-tv":
            return ShortcutStyle(word: "tv", background: .black, foreground: .white)
        case "spotify":
            return ShortcutStyle(word: "Spotify", background: Color(red: 0.11, green: 0.73, blue: 0.33), foreground: .black)
        default:
            return ShortcutStyle(word: slug, background: .remoteButton, foreground: .white)
        }
    }
}

private struct ShortcutDrag: ViewModifier {
    var enabled: Bool
    var slug: String
    var onMove: (String) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(slug)
                .dropDestination(for: String.self) { items, _ in
                    if let source = items.first {
                        onMove(source)
                    }
                    return true
                }
        } else {
            content
        }
    }
}

private struct RenameSheet: View {
    @Bindable var session: RemoteSession

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Name this TV")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                TextField("Name", text: $session.renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.words)
                Spacer()
            }
            .padding(22)
            .background(Color.remoteBackground.ignoresSafeArea())
            .navigationTitle("Rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { session.dismissRename() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { session.saveRename() }
                        .disabled(session.renameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
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

    private let choices = ["Auto", "Roku", "LG webOS"]

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
                    if isPIN {
                        TextField(entryTitle, text: $session.pairingDraft)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numberPad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        SecureField(entryTitle, text: $session.pairingDraft)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.asciiCapable)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if let pairingError = session.pairingError, !pairingError.isEmpty {
                        Text(pairingError)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.remoteDanger)
                    }
                    Button("Continue") {
                        session.submitPairing()
                    }
                    .buttonStyle(RemoteFillStyle(tint: .remoteAccent))
                    .disabled(session.pairingDraft.trimmingCharacters(in: .whitespaces).isEmpty)
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
