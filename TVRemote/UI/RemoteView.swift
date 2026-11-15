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
            ControlPad { session.press($0) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            mediaRow
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
            Image(style.asset)
                .resizable()
                .scaledToFit()
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(minWidth: 84, maxWidth: 132, minHeight: 48, maxHeight: 48)
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

    private var mediaRow: some View {
        HStack(spacing: 8) {
            mediaKey("Skip previous", systemImage: "backward.end.fill", key: .skipPrevious, compact: true)
            mediaKey("Rewind", systemImage: "backward.fill", key: .rewind, compact: false)
            mediaKey("Play", systemImage: "playpause.fill", key: .playPause, compact: false)
            mediaKey("Fast forward", systemImage: "forward.fill", key: .fastForward, compact: false)
            mediaKey("Skip next", systemImage: "forward.end.fill", key: .skipNext, compact: true)
        }
    }

    private func mediaKey(_ title: String, systemImage: String, key: RemoteKey, compact: Bool) -> some View {
        Button {
            session.press(key)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: compact ? 16 : 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: compact ? 52 : .infinity, minHeight: compact ? 46 : 54, maxHeight: compact ? 46 : 54)
                .background(Color.remoteButton, in: RoundedRectangle(cornerRadius: compact ? 14 : 16, style: .continuous))
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
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(tint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .accessibilityLabel(title)
    }

}

private struct ControlPad: View {
    var onPress: (RemoteKey) -> Void
    @State private var held: RemoteKey?
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            let metrics = PadMetrics(size: geo.size)
            ZStack {
                plus(metrics)
                cornerStack(metrics, side: .left)
                cornerStack(metrics, side: .right)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func plus(_ metrics: PadMetrics) -> some View {
        let center = metrics.crossCenter
        return ZStack {
            Capsule()
                .fill(Color.remoteButton)
                .frame(width: metrics.arm, height: metrics.size.height)
                .position(x: center.x, y: metrics.size.height / 2)
            Capsule()
                .fill(Color.remoteButton)
                .frame(width: metrics.size.width, height: metrics.arm)
                .position(x: center.x, y: center.y)
            Circle()
                .fill(held == .ok ? Color.remoteAccent.opacity(0.8) : Color.remoteAccent)
                .frame(width: metrics.arm, height: metrics.arm)
                .position(x: center.x, y: center.y)
            Text("OK")
                .font(.system(size: metrics.arm * 0.28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .position(x: center.x, y: center.y)
            chevron("chevron.up", at: metrics.upPoint)
            chevron("chevron.down", at: metrics.downPoint)
            chevron("chevron.left", at: metrics.leftPoint)
            chevron("chevron.right", at: metrics.rightPoint)
        }
        .frame(width: metrics.size.width, height: metrics.size.height)
        .contentShape(PlusHitShape(arm: metrics.arm, crossMidY: center.y))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let next = metrics.key(at: value.location)
                    guard next != held else { return }
                    if let next {
                        startHold(next)
                    } else {
                        stopHold()
                    }
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
        .accessibilityAction(named: "Volume up") { onPress(.volumeUp) }
        .accessibilityAction(named: "Volume down") { onPress(.volumeDown) }
        .accessibilityAction(named: "Mute") { onPress(.mute) }
        .accessibilityAction(named: "Channel up") { onPress(.channelUp) }
        .accessibilityAction(named: "Channel down") { onPress(.channelDown) }
        .onDisappear { stopHold() }
    }

    private func chevron(_ system: String, at point: CGPoint) -> some View {
        Image(systemName: system)
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(.white.opacity(0.92))
            .position(x: point.x, y: point.y)
            .accessibilityHidden(true)
    }

    private func cornerStack(_ metrics: PadMetrics, side: PadSide) -> some View {
        let pocket = metrics.pocket(side)
        let muteHeight = min(44, pocket.height * 0.32)
        return Group {
            if side == .left {
                VStack(spacing: 4) {
                    VStack(spacing: 0) {
                        cornerKey("Volume up", systemImage: "speaker.plus.fill", key: .volumeUp)
                        Rectangle().fill(.white.opacity(0.12)).frame(height: 1).padding(.horizontal, 8)
                        cornerKey("Volume down", systemImage: "speaker.minus.fill", key: .volumeDown)
                    }
                    .frame(maxHeight: .infinity)
                    .background(Color.remoteButton, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    cornerKey("Mute", systemImage: "speaker.slash.fill", key: .mute)
                        .frame(height: muteHeight)
                        .background(Color.remoteButton, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            } else {
                VStack(spacing: 0) {
                    cornerKey("Channel up", systemImage: "chevron.up", key: .channelUp)
                    Rectangle().fill(.white.opacity(0.12)).frame(height: 1).padding(.horizontal, 8)
                    cornerKey("Channel down", systemImage: "chevron.down", key: .channelDown)
                }
                .background(Color.remoteButton, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .frame(width: pocket.width, height: pocket.height)
        .position(pocket.center)
    }

    private func cornerKey(_ title: String, systemImage: String, key: RemoteKey) -> some View {
        Button {
            onPress(key)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel(title)
    }

    private func startHold(_ key: RemoteKey) {
        stopHold()
        held = key
        onPress(key)
        guard key == .up || key == .down || key == .left || key == .right else { return }
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

private enum PadSide {
    case left
    case right
}

private struct PadMetrics {
    var size: CGSize

    var arm: CGFloat {
        min(size.width, size.height) * 0.32
    }

    var crossCenter: CGPoint {
        let pocket = min(112, size.height * 0.40)
        let midY = min(size.height * 0.46, size.height - pocket - arm / 2)
        return CGPoint(x: size.width / 2, y: max(arm, midY))
    }

    var upPoint: CGPoint {
        CGPoint(x: crossCenter.x, y: (crossCenter.y - arm / 2) / 2)
    }

    var downPoint: CGPoint {
        let top = crossCenter.y + arm / 2
        return CGPoint(x: crossCenter.x, y: (top + size.height) / 2)
    }

    var leftPoint: CGPoint {
        CGPoint(x: (crossCenter.x - arm / 2) / 2, y: crossCenter.y)
    }

    var rightPoint: CGPoint {
        let left = crossCenter.x + arm / 2
        return CGPoint(x: (left + size.width) / 2, y: crossCenter.y)
    }

    func pocket(_ side: PadSide) -> (width: CGFloat, height: CGFloat, center: CGPoint) {
        let width = max(52, (size.width - arm) / 2 - 10)
        let top = crossCenter.y + arm / 2
        let height = max(72, size.height - top - 6)
        let centerY = size.height - height / 2 - 2
        let centerX = side == .left ? width / 2 + 2 : size.width - width / 2 - 2
        return (width, height, CGPoint(x: centerX, y: centerY))
    }

    func key(at point: CGPoint) -> RemoteKey? {
        let dx = point.x - crossCenter.x
        let dy = point.y - crossCenter.y
        let radius = arm / 2
        if hypot(dx, dy) <= radius {
            return .ok
        }
        if abs(dx) <= radius, abs(dy) > radius {
            return dy < 0 ? .up : .down
        }
        if abs(dy) <= radius, abs(dx) > radius {
            return dx < 0 ? .left : .right
        }
        return nil
    }
}

private struct PlusHitShape: Shape {
    var arm: CGFloat
    var crossMidY: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(
            in: CGRect(x: rect.midX - arm / 2, y: rect.minY, width: arm, height: rect.height),
            cornerSize: CGSize(width: arm / 2, height: arm / 2)
        )
        path.addRoundedRect(
            in: CGRect(x: rect.minX, y: crossMidY - arm / 2, width: rect.width, height: arm),
            cornerSize: CGSize(width: arm / 2, height: arm / 2)
        )
        return path
    }
}

private struct ShortcutStyle {
    var asset: String
    var background: Color

    static func style(for slug: String) -> ShortcutStyle {
        switch slug {
        case "netflix":
            return ShortcutStyle(asset: "LogoNetflix", background: Color(red: 0.08, green: 0.08, blue: 0.08))
        case "prime":
            return ShortcutStyle(asset: "LogoPrime", background: .white)
        case "disney":
            return ShortcutStyle(asset: "LogoDisney", background: .white)
        case "youtube":
            return ShortcutStyle(asset: "LogoYouTube", background: .white)
        case "youtube-tv":
            return ShortcutStyle(asset: "LogoYouTubeTV", background: .white)
        case "max":
            return ShortcutStyle(asset: "LogoMax", background: .white)
        case "hulu":
            return ShortcutStyle(asset: "LogoHulu", background: .black)
        case "peacock":
            return ShortcutStyle(asset: "LogoPeacock", background: .white)
        case "paramount":
            return ShortcutStyle(asset: "LogoParamount", background: .white)
        case "apple-tv":
            return ShortcutStyle(asset: "LogoAppleTV", background: .white)
        case "spotify":
            return ShortcutStyle(asset: "LogoSpotify", background: Color(red: 0.07, green: 0.07, blue: 0.07))
        default:
            return ShortcutStyle(asset: "LogoNetflix", background: .remoteButton)
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
