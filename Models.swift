import Foundation

enum BridgeError: LocalizedError {
    case invalidXML, invalidAddress, noSpeakers, requestFailed(String), responseTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidXML: return "The speaker returned an unreadable response."
        case .invalidAddress: return "Enter a local speaker IP address, such as 192.168.1.20."
        case .noSpeakers: return "No Sonos speakers found. Check your Wi-Fi or connect using a speaker IP address."
        case .requestFailed(let message): return message
        case .responseTooLarge: return "The speaker response was too large."
        }
    }
}

final class Element {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [Element] = []

    init(_ name: String, _ attributes: [String: String] = [:]) {
        self.name = name.split(separator: ":").last.map(String.init) ?? name
        self.attributes = attributes
    }

    func first(_ name: String) -> Element? {
        if self.name == name { return self }
        return children.lazy.compactMap { $0.first(name) }.first
    }

    func value(_ name: String) -> String { first(name)?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

    func descendants(_ name: String) -> [Element] {
        (self.name == name ? [self] : []) + children.flatMap { $0.descendants(name) }
    }

    static func parse(_ data: Data) throws -> Element {
        guard data.count <= 2 * 1_024 * 1_024 else { throw BridgeError.responseTooLarge }
        // Sonos uses UTF-8 XML and needs no document types or entity declarations.
        guard let text = String(data: data, encoding: .utf8), !text.contains("<!DOCTYPE") else { throw BridgeError.invalidXML }
        let delegate = XMLReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else { throw BridgeError.invalidXML }
        return root
    }

    static func parse(_ text: String) throws -> Element { try parse(Data(text.utf8)) }
}

private final class XMLReader: NSObject, XMLParserDelegate {
    var root: Element?
    private var stack: [Element] = []
    private var count = 0

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        count += 1
        guard stack.count < 32, count <= 16_384 else { parser.abortParsing(); return }
        let element = Element(name, attributes)
        if let parent = stack.last { parent.children.append(element) }
        else { root = element }
        stack.append(element)
    }

    func parser(_ parser: XMLParser, foundCharacters text: String) { stack.last?.text += text }
    func parser(_ parser: XMLParser, foundCDATA data: Data) { stack.last?.text += String(decoding: data, as: UTF8.self) }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
}

struct Room: Equatable {
    let id: String
    let name: String
    let address: URL
    let coordinator: URL

    static func baseURL(host: String) -> URL? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let a = UInt8(parts[0]), let b = UInt8(parts[1]),
              let c = UInt8(parts[2]), let d = UInt8(parts[3]),
              a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 169 && b == 254) else { return nil }
        return URL(string: "http://\(a).\(b).\(c).\(d):1400")
    }

    static func baseURL(location: String) -> URL? {
        guard let url = URL(string: location), url.scheme == "http", url.port == 1400,
              url.user == nil, url.password == nil, let host = url.host else { return nil }
        return baseURL(host: host)
    }

    static func parseTopology(_ xml: String) throws -> [Room] {
        let root = try Element.parse(xml)
        var rooms: [Room] = []
        for group in root.descendants("ZoneGroup") {
            let members = group.children.filter { $0.name == "ZoneGroupMember" }
            guard let coordinator = members.first(where: { $0.attributes["UUID"] == group.attributes["Coordinator"] }),
                  let location = coordinator.attributes["Location"], let address = baseURL(location: location) else { continue }
            for member in members where member.attributes["Invisible"] != "1" {
                guard let id = member.attributes["UUID"], !id.isEmpty,
                      let name = member.attributes["ZoneName"], !name.isEmpty,
                      let location = member.attributes["Location"], let ownAddress = baseURL(location: location),
                      !rooms.contains(where: { $0.id == id }) else { continue }
                rooms.append(Room(id: id, name: name, address: ownAddress, coordinator: address))
            }
        }
        guard !rooms.isEmpty else { throw BridgeError.noSpeakers }
        return rooms.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct Playback {
    let title: String
    let artist: String
    let album: String
    let artwork: URL?
    let duration: Double?
    let elapsed: Double?
    let state: String
    let actions: Set<String>
    let trackID: String

    var isPlaying: Bool { state == "PLAYING" || state == "TRANSITIONING" }
    var hasTrack: Bool { !title.isEmpty }
    var canToggle: Bool { actions.contains(isPlaying ? "Pause" : "Play") }
    var canSeek: Bool { actions.contains("Seek") && (duration ?? 0) > 0 }

    static func seconds(_ text: String) -> Double? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]),
              hours.isFinite, minutes.isFinite, seconds.isFinite,
              hours >= 0, hours.rounded(.down) == hours, (0..<60).contains(minutes), minutes.rounded(.down) == minutes,
              (0..<60).contains(seconds) else { return nil }
        let value = hours * 3600 + minutes * 60 + seconds
        return value.isFinite ? value : nil
    }

    init(position: Element, transport: Element, actions: Element, baseURL: URL) throws {
        let metadata = position.value("TrackMetaData")
        let track = metadata.isEmpty || metadata == "NOT_IMPLEMENTED" ? nil : try Element.parse(metadata)
        let rawTitle = track?.value("title") ?? ""
        title = rawTitle.isEmpty ? track?.value("streamContent") ?? "" : rawTitle
        artist = track?.value("creator") ?? ""
        album = track?.value("album") ?? ""
        let artworkPath = track?.value("albumArtURI") ?? ""
        let artworkURL = artworkPath.isEmpty ? nil : URL(string: artworkPath, relativeTo: baseURL)?.absoluteURL
        if let url = artworkURL, url.user == nil, url.password == nil,
           url.scheme == "https" || (url.scheme == "http" && url.host == baseURL.host && url.port == 1400) {
            artwork = url
        } else { artwork = nil }
        duration = Self.seconds(position.value("TrackDuration"))
        elapsed = Self.seconds(position.value("RelTime"))
        state = transport.value("CurrentTransportState")
        guard ["PLAYING", "PAUSED_PLAYBACK", "STOPPED", "TRANSITIONING", "NO_MEDIA_PRESENT"].contains(state) else {
            throw BridgeError.invalidXML
        }
        self.actions = Set(actions.value("Actions").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        trackID = position.value("TrackURI") + "|" + title + "|" + artist
    }
}
