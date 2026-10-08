import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
}
func rejects(_ message: String, _ operation: () throws -> Void) {
    do { try operation(); preconditionFailure(message) }
    catch { checks += 1 }
}
func escaped(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
}

let topology = """
<ZoneGroups><ZoneGroup Coordinator="A"><ZoneGroupMember UUID="B" ZoneName="Kitchen" Location="http://192.168.1.21:1400/xml/device_description.xml"/><ZoneGroupMember UUID="A" ZoneName="Office" Location="http://192.168.1.20:1400/xml/device_description.xml"/><ZoneGroupMember UUID="SUB" ZoneName="Sub" Invisible="1" Location="http://192.168.1.22:1400/xml/device_description.xml"/></ZoneGroup></ZoneGroups>
"""
let rooms = try Room.parseTopology(topology)
check(rooms.map(\.name) == ["Kitchen", "Office"], "Only visible rooms should be listed in order")
check(rooms[0].coordinator.host == "192.168.1.20", "Transport commands must use the group coordinator")
check(rooms[0].address.host == "192.168.1.21", "Room identity must keep its own address")
check(Room.baseURL(host: "172.16.0.1") != nil, "Private 172.16 addresses should be accepted")
check(Room.baseURL(host: "10.0.0.1") != nil, "Private 10 addresses should be accepted")
check(Room.baseURL(host: "169.254.1.2") != nil, "Link-local addresses should be accepted")
for address in ["8.8.8.8", "127.0.0.1", "172.32.0.1", "192.168.1.999", "localhost", "192.168.1.20:80", "192.168.1.20/path", "192.168.1.20\n"] {
    check(Room.baseURL(host: address) == nil, "Invalid or non-local speaker addresses must be refused: \(address)")
}
check(Room.baseURL(location: "http://user:pass@192.168.1.20:1400/xml/device.xml") == nil, "Discovery URLs must not contain credentials")
check(Room.baseURL(location: "https://192.168.1.20:1400/xml/device.xml") == nil, "Discovery must match Sonos' local HTTP endpoint")
rejects("Malformed XML should be rejected") { _ = try Element.parse("<broken>") }
rejects("Internal XML entities should be rejected") { _ = try Element.parse("<!DOCTYPE x [<!ENTITY a 'value'>]><x>&a;</x>") }
rejects("External XML entities should be rejected") { _ = try Element.parse("<!DOCTYPE x [<!ENTITY a SYSTEM 'file:///etc/passwd'>]><x>&a;</x>") }
rejects("Topology without a coordinator must not create controllable rooms") { _ = try Room.parseTopology("<ZoneGroups><ZoneGroup Coordinator='missing'><ZoneGroupMember UUID='A' ZoneName='Office' Location='http://192.168.1.20:1400/xml/device.xml'/></ZoneGroup></ZoneGroups>") }
rejects("Deeply nested XML should be rejected") { _ = try Element.parse(String(repeating: "<a>", count: 40) + String(repeating: "</a>", count: 40)) }
check(Playback.seconds("1:02:03") == 3723, "Hour-long tracks must parse correctly")
check(Playback.seconds("0:00:00") == 0, "Live stream zero durations must remain zero")
for value in ["NOT_IMPLEMENTED", "", "0:99:00", "-1:00:00", "nan:00:00", "inf:00:00", "0:00:60", "0:0"] {
    check(Playback.seconds(value) == nil, "Invalid or unknown times must not become a timeline: \(value)")
}
let metadata = "<DIDL-Lite xmlns:dc='urn:dc' xmlns:upnp='urn:upnp'><item><dc:title>Fish &amp; Chips</dc:title><dc:creator>Artist</dc:creator><upnp:album>Album</upnp:album><upnp:albumArtURI>/getaa?x=1&amp;y=2</upnp:albumArtURI></item></DIDL-Lite>"
let position = try Element.parse("<response><TrackMetaData>\(escaped(metadata))</TrackMetaData><TrackURI>track:1</TrackURI><TrackDuration>0:03:00</TrackDuration><RelTime>0:00:20</RelTime></response>")
let transport = try Element.parse("<response><CurrentTransportState>PLAYING</CurrentTransportState></response>")
let actions = try Element.parse("<response><Actions> Play, Pause, Next </Actions></response>")
let playing = try Playback(position: position, transport: transport, actions: actions, baseURL: rooms[1].address)
check(playing.title == "Fish & Chips", "Nested XML must decode entities exactly once per layer")
check(playing.artist == "Artist" && playing.album == "Album", "Namespaced metadata should be read")
check(playing.artwork?.host == "192.168.1.20" && playing.artwork?.path == "/getaa", "Relative artwork belongs to the coordinator")
check(playing.isPlaying && playing.canToggle, "Playing tracks with Pause must be controllable")
check(playing.actions.contains("Next") && !playing.actions.contains("Previous"), "Unsupported commands must stay unavailable")
check(!playing.canSeek, "A duration alone must not advertise unsupported seeking")
let empty = try Playback(position: Element.parse("<response><TrackMetaData>NOT_IMPLEMENTED</TrackMetaData><TrackDuration>NOT_IMPLEMENTED</TrackDuration></response>"), transport: transport, actions: actions, baseURL: rooms[1].address)
check(!empty.hasTrack && empty.duration == nil && empty.artwork == nil, "Missing metadata must clear playback without a fabricated track")
let unsafeArt = try Playback(position: Element.parse("<response><TrackMetaData>\(escaped(metadata.replacingOccurrences(of: "/getaa?x=1&amp;y=2", with: "http://8.8.8.8/image")))</TrackMetaData></response>"), transport: transport, actions: actions, baseURL: rooms[1].address)
check(unsafeArt.artwork == nil, "Artwork must not load arbitrary plain HTTP addresses")
rejects("An unknown transport state must not become an invented paused state") {
    _ = try Playback(position: position, transport: Element.parse("<response/>"), actions: actions, baseURL: rooms[1].address)
}
let paused = try Playback(position: position, transport: Element.parse("<response><CurrentTransportState>PAUSED_PLAYBACK</CurrentTransportState></response>"), actions: actions, baseURL: rooms[1].address)
check(!paused.isPlaying && paused.canToggle, "Paused playback must offer Play")
let seekable = try Playback(position: position, transport: transport, actions: Element.parse("<response><Actions>Play,Pause,Seek</Actions></response>"), baseURL: rooms[1].address)
check(seekable.canSeek, "Seeking needs both a duration and the speaker's advertised Seek action")
print("Passed \(checks) model checks.")
