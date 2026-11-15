import SwiftUI
import UIKit

enum Haptics {
    private static let tapImpact = UIImpactFeedbackGenerator(style: .medium)
    private static let firmImpact = UIImpactFeedbackGenerator(style: .heavy)

    static func prepare() {
        tapImpact.prepare()
        firmImpact.prepare()
    }

    static func tap() {
        tapImpact.impactOccurred(intensity: 1.0)
        prepare()
    }

    static func firmTap() {
        firmImpact.impactOccurred(intensity: 1.0)
        prepare()
    }
}

extension Color {
    static let remoteBackground = Color(red: 11 / 255, green: 12 / 255, blue: 15 / 255)
    static let remoteRaised = Color(red: 0.11, green: 0.12, blue: 0.15)
    static let remoteButton = Color(red: 42 / 255, green: 44 / 255, blue: 55 / 255)
    static let remoteAccent = Color(red: 127 / 255, green: 140 / 255, blue: 247 / 255)
    static let remotePower = Color(red: 211 / 255, green: 101 / 255, blue: 86 / 255)
    static let remoteDanger = Color(red: 0.89, green: 0.36, blue: 0.31)
    static let remoteWarning = Color(red: 0.93, green: 0.72, blue: 0.32)
    static let remoteOK = Color(red: 134 / 255, green: 197 / 255, blue: 138 / 255)
    static let remoteMore = Color(red: 218 / 255, green: 219 / 255, blue: 219 / 255)
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

    private var showsError: Bool {
        session.linkState == .notFound || session.linkState == .lost
    }

    private var controls: some View {
        GeometryReader { geo in
            let stage = Stage(
                width: geo.size.width,
                height: geo.size.height,
                safeTop: geo.safeAreaInsets.top,
                safeBottom: geo.safeAreaInsets.bottom,
                showsError: showsError,
                editing: editingShortcuts
            )
            ZStack(alignment: .topLeading) {
                powerButton(stage)
                nameControl(stage)
                moreButton(stage)
                if showsError {
                    statusLine(stage)
                }
                controlRow(stage)
                shortcutRow(stage)
                PlusPad(side: stage.s(370), arm: stage.s(148), okSize: stage.s(116), okCorner: stage.s(24), cornerRadius: stage.s(16)) {
                    session.press($0)
                }
                .frame(width: stage.s(370), height: stage.s(370))
                .position(x: stage.x(16 + 185), y: stage.y(299) + stage.s(185))
                backButton(stage)
                volumeGroup(stage)
                channelGroup(stage)
                mediaRow(stage)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }

    private func powerButton(_ stage: Stage) -> some View {
        Button(action: session.power) {
            Image(systemName: "power")
                .font(.system(size: stage.s(26), weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: stage.s(86.5), height: stage.s(52))
                .background(Color.remotePower, in: RoundedRectangle(cornerRadius: stage.s(18)))
        }
        .accessibilityLabel("Power")
        .position(x: stage.x(16 + 43.25), y: stage.y(66) + stage.s(26))
    }

    private func nameControl(_ stage: Stage) -> some View {
        Group {
            if session.needsReconnect {
                Button(action: session.retry) { nameLabel(stage) }
            } else {
                Menu { televisionMenu } label: { nameLabel(stage) }
            }
        }
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
            session.beginRename()
        })
        .position(x: stage.x(201), y: stage.y(92))
    }

    private func nameLabel(_ stage: Stage) -> some View {
        HStack(spacing: stage.s(8)) {
            Circle()
                .fill(statusColor)
                .frame(width: stage.s(11), height: stage.s(11))
                .accessibilityLabel(statusAccessibility)
            Text(session.activeDevice.map { session.displayName(for: $0) } ?? "No Ads Remote")
                .font(.system(size: stage.s(23), weight: .bold))
                .tracking(stage.s(-0.4))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: stage.s(220))
    }

    private func moreButton(_ stage: Stage) -> some View {
        Menu {
            televisionMenu
            Button("Scan Wi-Fi") { session.rescan() }
            if session.activeDevice != nil {
                Button("Forget this TV", role: .destructive) { session.confirmForget = true }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: stage.s(13), weight: .black))
                .foregroundStyle(Color.remoteButton)
                .frame(width: stage.s(26), height: stage.s(26))
                .background(Color.remoteMore, in: Circle())
        }
        .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
        .accessibilityLabel("More")
        .position(x: stage.x(360 + 13), y: stage.y(79) + stage.s(13))
    }

    @ViewBuilder
    private var televisionMenu: some View {
        ForEach(session.devices) { device in
            Button {
                Haptics.tap()
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

    private func statusLine(_ stage: Stage) -> some View {
        HStack(spacing: stage.s(8)) {
            Circle()
                .fill(statusColor)
                .frame(width: stage.s(8), height: stage.s(8))
            Text(session.statusText)
                .font(.system(size: stage.s(14), weight: .medium))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry") { session.retry() }
                .font(.system(size: stage.s(14), weight: .bold))
                .foregroundStyle(Color.remoteAccent)
        }
        .padding(.horizontal, stage.s(12))
        .frame(width: stage.s(370), height: stage.s(32))
        .background(statusColor.opacity(0.14), in: RoundedRectangle(cornerRadius: stage.s(12)))
        .position(x: stage.x(16 + 185), y: stage.y(122) + stage.s(16))
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

    private func controlRow(_ stage: Stage) -> some View {
        HStack(spacing: stage.s(8)) {
            rowButton("Home", systemImage: "house.fill", stage: stage) { session.press(.home) }
            rowButton("Input", systemImage: "rectangle.connected.to.line.below", stage: stage) { session.openInputs() }
            rowButton("Menu", systemImage: "gearshape.fill", stage: stage) { session.press(.menu) }
            rowButton("Keyboard", systemImage: "keyboard", stage: stage) { session.openKeyboard() }
        }
        .frame(width: stage.s(370), height: stage.s(76))
        .position(x: stage.x(16 + 185), y: stage.y(130) + stage.s(38))
    }

    private func rowButton(_ title: String, systemImage: String, stage: Stage, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: stage.s(6)) {
                Image(systemName: systemImage)
                    .font(.system(size: stage.s(24), weight: .semibold))
                Text(title)
                    .font(.system(size: stage.s(13), weight: .semibold))
                    .tracking(stage.s(-0.15))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.remoteButton, in: RoundedRectangle(cornerRadius: stage.s(22)))
        }
        .accessibilityLabel(title)
    }

    private func shortcutRow(_ stage: Stage) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: stage.s(8)) {
                if editingShortcuts {
                    Button("Done") { editingShortcuts = false }
                        .font(.system(size: stage.s(15), weight: .bold))
                        .foregroundStyle(.white)
                        .frame(height: stage.s(54))
                }
                ForEach(Array(session.visibleShortcuts.enumerated()), id: \.element.id) { index, shortcut in
                    shortcutTile(shortcut, index: index, stage: stage)
                }
                if editingShortcuts {
                    ForEach(session.hiddenShortcuts) { shortcut in
                        Button("Show \(shortcut.title)") {
                            session.setShortcut(shortcut.slug, hidden: false)
                        }
                        .font(.system(size: stage.s(13), weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(height: stage.s(54))
                    }
                }
            }
            .padding(.leading, stage.s(16))
            .padding(.trailing, stage.s(16))
        }
        .scrollIndicators(.hidden)
        .frame(width: stage.width, height: stage.s(editingShortcuts ? 82 : 54))
        .position(x: stage.width / 2, y: stage.y(218) + stage.s(editingShortcuts ? 41 : 27))
    }

    private func shortcutTile(_ shortcut: AppShortcut, index: Int, stage: Stage) -> some View {
        let style = ShortcutStyle.style(for: shortcut.slug)
        return VStack(spacing: 4) {
            ZStack {
                Image(style.asset)
                    .resizable()
                    .scaledToFit()
                    .frame(width: stage.s(style.logoWidth), height: stage.s(style.logoHeight))
            }
            .frame(width: stage.s(96), height: stage.s(54))
            .background(style.background, in: RoundedRectangle(cornerRadius: stage.s(18)))
            .rotationEffect(.degrees(editingShortcuts ? (index.isMultiple(of: 2) ? -2 : 2) : 0))
            .animation(editingShortcuts ? .easeInOut(duration: 0.14).repeatForever(autoreverses: true) : .default, value: editingShortcuts)
            if editingShortcuts {
                Button("Hide") { session.setShortcut(shortcut.slug, hidden: true) }
                    .font(.system(size: 12, weight: .bold))
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

    private func backButton(_ stage: Stage) -> some View {
        Button { session.press(.back) } label: {
            VStack(spacing: stage.s(6)) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: stage.s(22), weight: .semibold))
                Text("Back")
                    .font(.system(size: stage.s(13), weight: .semibold))
                    .tracking(stage.s(-0.15))
            }
            .foregroundStyle(.white)
            .frame(width: stage.s(87), height: stage.s(76))
            .background(Color.remoteButton, in: RoundedRectangle(cornerRadius: stage.s(20)))
        }
        .accessibilityLabel("Back")
        .position(x: stage.x(299 + 43.5), y: stage.y(299) + stage.s(38))
    }

    private func volumeGroup(_ stage: Stage) -> some View {
        VStack(spacing: stage.s(6)) {
            VStack(spacing: 0) {
                cornerIcon("speaker.plus.fill", label: "Volume up", key: .volumeUp, stage: stage)
                Rectangle()
                    .fill(Color.white.opacity(0.22))
                    .frame(height: 1)
                    .padding(.horizontal, stage.s(14))
                cornerIcon("speaker.minus.fill", label: "Volume down", key: .volumeDown, stage: stage)
            }
            .frame(height: stage.s(122))
            .background(Color.remoteButton, in: RoundedRectangle(cornerRadius: stage.s(16)))
            Button { session.press(.mute) } label: {
                Image(systemName: "speaker.slash.fill")
                    .font(.system(size: stage.s(18), weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.remoteButton, in: RoundedRectangle(cornerRadius: stage.s(14)))
            }
            .frame(height: stage.s(44))
            .accessibilityLabel("Mute")
        }
        .frame(width: stage.s(87), height: stage.s(172))
        .position(x: stage.x(16 + 43.5), y: stage.y(582) + stage.s(86))
    }

    private func channelGroup(_ stage: Stage) -> some View {
        VStack(spacing: 0) {
            channelHalf("CH+", label: "Channel up", key: .channelUp, stage: stage)
            Rectangle()
                .fill(Color.white.opacity(0.22))
                .frame(height: 1)
                .padding(.horizontal, stage.s(14))
            channelHalf("CH−", label: "Channel down", key: .channelDown, stage: stage)
        }
        .frame(width: stage.s(87), height: stage.s(172))
        .background(Color.remoteButton, in: RoundedRectangle(cornerRadius: stage.s(16)))
        .position(x: stage.x(299 + 43.5), y: stage.y(582) + stage.s(86))
    }

    private func cornerIcon(_ system: String, label: String, key: RemoteKey, stage: Stage) -> some View {
        Button { session.press(key) } label: {
            Image(systemName: system)
                .font(.system(size: stage.s(20), weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel(label)
    }

    private func channelHalf(_ title: String, label: String, key: RemoteKey, stage: Stage) -> some View {
        Button { session.press(key) } label: {
            Text(title)
                .font(.system(size: stage.s(18), weight: .bold))
                .tracking(stage.s(-0.2))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel(label)
    }

    private func mediaRow(_ stage: Stage) -> some View {
        HStack(spacing: stage.s(8)) {
            mediaKey("Skip previous", systemImage: "backward.end.fill", key: .skipPrevious, compact: true, stage: stage)
            mediaKey("Rewind", systemImage: "backward.fill", key: .rewind, compact: false, stage: stage)
            mediaKey("Play", systemImage: "playpause.fill", key: .playPause, compact: false, stage: stage)
            mediaKey("Fast forward", systemImage: "forward.fill", key: .fastForward, compact: false, stage: stage)
            mediaKey("Skip next", systemImage: "forward.end.fill", key: .skipNext, compact: true, stage: stage)
        }
        .frame(width: stage.s(370), height: stage.s(54))
        .position(x: stage.x(16 + 185), y: stage.y(778) + stage.s(27))
    }

    private func mediaKey(_ title: String, systemImage: String, key: RemoteKey, compact: Bool, stage: Stage) -> some View {
        Button { session.press(key) } label: {
            Image(systemName: systemImage)
                .font(.system(size: stage.s(compact ? 16 : 22), weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: compact ? stage.s(52) : .infinity, maxHeight: .infinity)
                .background(Color.remoteButton, in: RoundedRectangle(cornerRadius: stage.s(16)))
        }
        .accessibilityLabel(title)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tv")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(Color.remoteAccent)
            Text("No Ads Remote")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(.white)
            Text(session.isScanning ? "Looking on this Wi-Fi…" : "No TV yet. Scan the network or add one by IP address.")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button("Scan Wi-Fi") { session.rescan() }
                .buttonStyle(RemoteFillStyle(tint: .remoteAccent))
            Button("Add by IP") { session.showManualAdd = true }
                .buttonStyle(RemoteFillStyle(tint: .remoteButton))
        }
        .padding(24)
    }

}

private struct Stage {
    var width: CGFloat
    var height: CGFloat
    var safeTop: CGFloat
    var safeBottom: CGFloat
    var showsError: Bool
    var editing: Bool

    private let designW: CGFloat = 402
    private let designTopInset: CGFloat = 59
    private var designAvail: CGFloat { 781 }
    private var extra: CGFloat { (showsError ? 40 : 0) + (editing ? 28 : 0) }

    var scale: CGFloat {
        let avail = max(1, height - safeTop - safeBottom)
        return min(width / designW, avail / (designAvail + extra))
    }

    var originX: CGFloat { (width - designW * scale) / 2 }
    var originY: CGFloat {
        let avail = max(0, height - safeTop - safeBottom)
        let block = (designAvail + extra) * scale
        return safeTop + max(0, (avail - block) / 2)
    }

    func x(_ designX: CGFloat) -> CGFloat { originX + designX * scale }
    func y(_ designY: CGFloat) -> CGFloat {
        var shift: CGFloat = 0
        if showsError, designY >= 130 { shift += 40 }
        if editing, designY >= 218 { shift += 28 }
        return originY + (designY - designTopInset + shift) * scale
    }

    func s(_ value: CGFloat) -> CGFloat { value * scale }
}

private struct PlusPad: View {
    var side: CGFloat
    var arm: CGFloat
    var okSize: CGFloat
    var okCorner: CGFloat
    var cornerRadius: CGFloat
    var onPress: (RemoteKey) -> Void
    @State private var held: RemoteKey?
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        let center = CGPoint(x: side / 2, y: side / 2)
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
                .fill(Color.remoteButton)
                .frame(width: arm, height: side)
                .position(center)
            RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
                .fill(Color.remoteButton)
                .frame(width: side, height: arm)
                .position(center)
            RoundedRectangle(cornerRadius: okCorner, style: .continuous)
                .fill(held == .ok ? Color.remoteAccent.opacity(0.82) : Color.remoteAccent)
                .frame(width: okSize, height: okSize)
                .position(center)
            Text("OK")
                .font(.system(size: side * 32 / 370, weight: .bold))
                .tracking(side * -0.6 / 370)
                .foregroundStyle(.white)
                .position(center)
            chevron(-90, at: CGPoint(x: center.x, y: side * 58 / 370))
            chevron(90, at: CGPoint(x: center.x, y: side - side * 58 / 370))
            chevron(180, at: CGPoint(x: side * 58 / 370, y: center.y))
            chevron(0, at: CGPoint(x: side - side * 58 / 370, y: center.y))
        }
        .frame(width: side, height: side)
        .contentShape(PlusHitShape(arm: arm, radius: cornerRadius))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let next = key(at: value.location)
                    guard next != held else { return }
                    if let next {
                        startHold(next)
                    } else {
                        stopHold()
                    }
                }
                .onEnded { _ in stopHold() }
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

    private func chevron(_ degrees: Double, at point: CGPoint) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: side * 26 / 370, weight: .bold))
            .foregroundStyle(.white)
            .rotationEffect(.degrees(degrees))
            .position(point)
            .accessibilityHidden(true)
    }

    private func key(at point: CGPoint) -> RemoteKey? {
        let center = CGPoint(x: side / 2, y: side / 2)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let inVertical = abs(dx) <= arm / 2 && abs(dy) <= side / 2
        let inHorizontal = abs(dy) <= arm / 2 && abs(dx) <= side / 2
        guard inVertical || inHorizontal else { return nil }
        let inOK = abs(dx) <= okSize / 2 && abs(dy) <= okSize / 2
        // The previous OK target was a 124pt circle, not the 148pt arm crossing.
        let inPreviousCircle = hypot(dx, dy) <= side * 62 / 370
        if inOK || inPreviousCircle { return .ok }
        if abs(dx) > abs(dy) { return dx < 0 ? .left : .right }
        return dy < 0 ? .up : .down
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

private struct PlusHitShape: Shape {
    var arm: CGFloat
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(
            in: CGRect(x: rect.midX - arm / 2, y: rect.minY, width: arm, height: rect.height),
            cornerSize: CGSize(width: radius, height: radius)
        )
        path.addRoundedRect(
            in: CGRect(x: rect.minX, y: rect.midY - arm / 2, width: rect.width, height: arm),
            cornerSize: CGSize(width: radius, height: radius)
        )
        return path
    }
}

private struct ShortcutStyle {
    var asset: String
    var background: Color
    var logoWidth: CGFloat
    var logoHeight: CGFloat

    static func style(for slug: String) -> ShortcutStyle {
        switch slug {
        case "netflix":
            return ShortcutStyle(asset: "LogoNetflix", background: .white, logoWidth: 68, logoHeight: 28)
        case "prime":
            return ShortcutStyle(asset: "LogoPrime", background: Color(red: 7 / 255, green: 121 / 255, blue: 255 / 255), logoWidth: 68, logoHeight: 32)
        case "disney":
            return ShortcutStyle(asset: "LogoDisney", background: Color(red: 1 / 255, green: 20 / 255, blue: 124 / 255), logoWidth: 70, logoHeight: 36)
        case "youtube":
            return ShortcutStyle(asset: "LogoYouTube", background: .white, logoWidth: 64, logoHeight: 28)
        case "hulu":
            return ShortcutStyle(asset: "LogoHulu", background: .white, logoWidth: 58, logoHeight: 28)
        case "peacock":
            return ShortcutStyle(asset: "LogoPeacock", background: .white, logoWidth: 64, logoHeight: 28)
        case "paramount":
            return ShortcutStyle(asset: "LogoParamount", background: .white, logoWidth: 64, logoHeight: 26)
        case "apple-tv":
            return ShortcutStyle(asset: "LogoAppleTV", background: .white, logoWidth: 62, logoHeight: 28)
        case "spotify":
            return ShortcutStyle(asset: "LogoSpotify", background: Color(red: 18 / 255, green: 18 / 255, blue: 18 / 255), logoWidth: 34, logoHeight: 34)
        case "youtube-tv":
            return ShortcutStyle(asset: "LogoYouTubeTV", background: .white, logoWidth: 64, logoHeight: 28)
        case "max":
            return ShortcutStyle(asset: "LogoMax", background: .white, logoWidth: 58, logoHeight: 24)
        default:
            return ShortcutStyle(asset: "LogoNetflix", background: .remoteButton, logoWidth: 60, logoHeight: 28)
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
