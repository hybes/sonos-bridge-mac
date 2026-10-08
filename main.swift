import AppKit
import MediaPlayer
import ServiceManagement

@MainActor
final class BridgeApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let client = SonosClient()
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var rooms: [Room] = []
    private var selectedID: String?
    private var playback: Playback?
    private var artwork: NSImage?
    private var artworkURL: URL?
    private var artworkTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var generation = UUID()
    private var lastDiscovery = Date.distantPast
    private var status = "Searching for Sonos…"
    private var commandError: String?
    private var commandPending = false
    private var menuOpen = false
    private var publishedTrackID: String?
    private var publishedState: String?
    private var publishedDuration: Double?
    private var publishedAt = Date.distantPast
    private var publishedElapsed: Double?

    private var room: Room? { rooms.first { $0.id == selectedID } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        selectedID = defaults.string(forKey: "selectedRoom")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "hifispeaker.fill", accessibilityDescription: "Sonos Bridge")
        statusItem.button?.setAccessibilityLabel("Sonos Bridge")
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        registerCommands()
        rebuildMenu()
        startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitorTask?.cancel()
        commandTask?.cancel()
        artworkTask?.cancel()
        clearPlayback()
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        generation = UUID()
        let token = generation
        monitorTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.generation == token {
                await self.refresh(token: token)
                let seconds: UInt64 = self.playback == nil ? 15 : (self.playback?.isPlaying == true ? 2 : 5)
                do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) }
                catch { return }
            }
        }
    }

    private func refresh(token: UUID) async {
        guard !commandPending else { return }
        do {
            if rooms.isEmpty || Date().timeIntervalSince(lastDiscovery) >= 60 {
                let cached = rooms.compactMap { $0.address.host } + [defaults.string(forKey: "lastSpeaker")].compactMap { $0 }
                let found = try await client.discover(cachedHosts: cached)
                guard generation == token, !Task.isCancelled else { return }
                rooms = found
                lastDiscovery = Date()
                if !rooms.contains(where: { $0.id == selectedID }) {
                    selectedID = rooms.first?.id
                    defaults.set(selectedID, forKey: "selectedRoom")
                }
            }
            guard let room else { throw BridgeError.noSpeakers }
            let snapshot = try await client.playback(in: room)
            guard generation == token, self.room == room, !Task.isCancelled else { return }
            defaults.set(room.address.host, forKey: "lastSpeaker")
            receive(snapshot, room: room)
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            status = rooms.isEmpty ? error.localizedDescription : "Can't reach \(room?.name ?? "Sonos"). Reconnecting…"
            lastDiscovery = .distantPast
            clearPlayback()
            updateMenu()
        }
    }

    private func receive(_ snapshot: Playback, room: Room) {
        playback = snapshot
        status = snapshot.hasTrack ? "\(snapshot.isPlaying ? "Playing" : "Paused") in \(room.name)" : "Nothing playing in \(room.name)"
        if snapshot.artwork != artworkURL {
            artworkTask?.cancel()
            artworkURL = snapshot.artwork
            artwork = nil
            if let url = snapshot.artwork {
                let selectedRoom = room.id
                artworkTask = Task { [weak self] in
                    guard let self, let data = try? await self.client.artwork(at: url), !Task.isCancelled,
                          self.room?.id == selectedRoom, self.artworkURL == url, let image = NSImage(data: data) else { return }
                    self.artwork = image
                    self.publish(force: true)
                }
            }
        }
        publish()
        updateMenu()
    }

    private func clearPlayback() {
        playback = nil
        artworkTask?.cancel()
        artwork = nil
        artworkURL = nil
        publishedTrackID = nil
        publishedState = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        updateCommands()
    }

    private func publish(force: Bool = false) {
        updateCommands()
        guard let playback, playback.hasTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            publishedTrackID = nil
            return
        }
        let extrapolated = (publishedElapsed ?? 0) + (publishedState == "PLAYING" ? Date().timeIntervalSince(publishedAt) : 0)
        guard force || publishedTrackID != playback.trackID || publishedState != playback.state
            || publishedDuration != playback.duration
            || abs((playback.elapsed ?? 0) - extrapolated) > 2 else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: playback.title,
            MPMediaItemPropertyArtist: playback.artist,
            MPMediaItemPropertyAlbumTitle: playback.album,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: playback.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyExternalContentIdentifier: playback.trackID,
            MPNowPlayingInfoPropertyIsLiveStream: (playback.duration ?? 0) == 0
        ]
        if let duration = playback.duration, duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let elapsed = playback.elapsed { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed }
        if let artwork { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork } }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = playback.isPlaying ? .playing : .paused
        publishedTrackID = playback.trackID
        publishedState = playback.state
        publishedDuration = playback.duration
        publishedElapsed = playback.elapsed
        publishedAt = Date()
    }

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        for (command, action) in [
            (center.playCommand, "Play"), (center.pauseCommand, "Pause"),
            (center.stopCommand, "Stop"), (center.togglePlayPauseCommand, "Toggle"),
            (center.nextTrackCommand, "Next"), (center.previousTrackCommand, "Previous"),
            (center.changePlaybackPositionCommand, "Seek")
        ] {
            command.addTarget { [weak self] event in
                let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
                Task { @MainActor in self?.send(action, position: position) }
                return .success
            }
        }
        updateCommands()
    }

    private func updateCommands() {
        let center = MPRemoteCommandCenter.shared()
        let available = playback?.hasTrack == true && !commandPending
        let actions = playback?.actions ?? []
        center.playCommand.isEnabled = available && actions.contains("Play")
        center.pauseCommand.isEnabled = available && actions.contains("Pause")
        center.stopCommand.isEnabled = available && actions.contains("Stop")
        center.togglePlayPauseCommand.isEnabled = available && playback?.canToggle == true
        center.nextTrackCommand.isEnabled = available && actions.contains("Next")
        center.previousTrackCommand.isEnabled = available && actions.contains("Previous")
        center.changePlaybackPositionCommand.isEnabled = available && playback?.canSeek == true
    }

    private func send(_ requested: String, position: Double? = nil) {
        guard !commandPending, let room, let playback, playback.hasTrack else { return }
        let action = requested == "Toggle" ? (playback.isPlaying ? "Pause" : "Play") : requested
        guard playback.actions.contains(action), action != "Seek" || playback.canSeek else { return }
        commandPending = true
        commandError = nil
        updateCommands()
        updateMenu()
        let token = generation
        commandTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.command(action, in: room, position: position)
                let snapshot = try await self.client.playback(in: room)
                guard self.generation == token, self.room == room, !Task.isCancelled else { return }
                self.commandPending = false
                self.receive(snapshot, room: room)
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.commandPending = false
                self.commandError = "Sonos couldn't complete that command. Try again."
                self.updateCommands()
                self.updateMenu()
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) { rebuildMenu(); menuOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    private func updateMenu() {
        statusItem?.button?.toolTip = ["Sonos Bridge", status, playback?.title].compactMap { $0 }.joined(separator: "\n")
        if !menuOpen { rebuildMenu() }
    }

    @discardableResult
    private func item(_ title: String, action: Selector? = nil, enabled: Bool = true, in target: NSMenu? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: String(title.prefix(70)), action: action, keyEquivalent: "")
        item.toolTip = title
        item.target = self
        item.isEnabled = action != nil && enabled
        (target ?? menu).addItem(item)
        return item
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        if let playback, playback.hasTrack {
            item(playback.title)
            if !playback.artist.isEmpty { item(playback.artist) }
        }
        item(commandPending ? "Sending command…" : status)
        if let commandError { item(commandError) }
        menu.addItem(.separator())
        let roomMenu = NSMenu(title: "Room")
        roomMenu.autoenablesItems = false
        for room in rooms {
            let entry = item(room.name, action: #selector(selectRoom(_:)), in: roomMenu)
            entry.representedObject = room.id
            entry.state = room.id == selectedID ? .on : .off
        }
        let selector = NSMenuItem(title: "Room: \(room?.name ?? "Not connected")", action: nil, keyEquivalent: "")
        selector.submenu = roomMenu
        selector.isEnabled = !rooms.isEmpty
        menu.addItem(selector)
        let enabled = playback?.hasTrack == true && !commandPending
        item(playback?.isPlaying == true ? "Pause" : "Play", action: #selector(togglePlayback), enabled: enabled && playback?.canToggle == true)
        item("Next Track", action: #selector(nextTrack), enabled: enabled && playback?.actions.contains("Next") == true)
        item("Previous Track", action: #selector(previousTrack), enabled: enabled && playback?.actions.contains("Previous") == true)
        menu.addItem(.separator())
        item("Find Speakers Again", action: #selector(findSpeakers))
        item("Connect Using Speaker IP…", action: #selector(connectByIP))
        item("Open Sonos Web", action: #selector(openSonos))
        menu.addItem(.separator())
        let login = item("Open at Login", action: #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        item("Quit Sonos Bridge", action: #selector(quit))
    }

    @objc private func selectRoom(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, rooms.contains(where: { $0.id == id }) else { return }
        selectedID = id
        defaults.set(id, forKey: "selectedRoom")
        commandTask?.cancel()
        commandPending = false
        commandError = nil
        clearPlayback()
        status = "Connecting to \(room?.name ?? "Sonos")…"
        updateMenu()
        startMonitoring()
    }

    @objc private func togglePlayback() { send("Toggle") }
    @objc private func nextTrack() { send("Next") }
    @objc private func previousTrack() { send("Previous") }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func findSpeakers() {
        commandTask?.cancel()
        commandPending = false
        lastDiscovery = .distantPast
        commandError = nil
        startMonitoring()
    }

    @objc private func connectByIP() {
        let alert = NSAlert()
        alert.messageText = "Connect to a speaker"
        alert.informativeText = "Enter a Sonos speaker's local IP address."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "192.168.1.20"
        field.stringValue = defaults.string(forKey: "lastSpeaker") ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let host = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Room.baseURL(host: host) != nil else {
            commandError = BridgeError.invalidAddress.localizedDescription
            updateMenu()
            return
        }
        commandTask?.cancel()
        commandPending = false
        clearPlayback()
        rooms = []
        defaults.set(host, forKey: "lastSpeaker")
        status = "Connecting to Sonos…"
        lastDiscovery = .distantPast
        updateMenu()
        startMonitoring()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
            commandError = nil
        } catch { commandError = "Couldn't change Open at Login: \(error.localizedDescription)" }
        updateMenu()
    }

    @objc private func openSonos() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.hybes.sonos-web") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else if let url = URL(string: "https://play.sonos.com") { NSWorkspace.shared.open(url) }
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = BridgeApp()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { application.run() }
}
