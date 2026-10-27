import AppKit
import CryptoKit
import Network

/// Music in the Spotify app, without clicking around it: Spotify's Web API finds what to play (with
/// the user's own developer keys, in Spotify.json in Shhh's folder), and the app's
/// AppleScript plays it. Simple requests ("play Fly Me to the Moon", "pause", "skip", "volume
/// down") are handled here at once, without asking Claude; Claude uses `Shhh --spotify …` for the rest.
enum Spotify {
    enum Kind: String { case track, album, artist, playlist }

    // MARK: - Understanding a request

    enum Command {
        case play(String, Kind?)
        /// A Spotify link or URI found elsewhere (a web search): played as is, no search needed.
        case playLink(String)
        /// Their own library (needs `Shhh --spotify-login` once).
        case likedSongs(shuffle: Bool), myPlaylist(String, shuffle: Bool), like, listPlaylists, unlike(String?)
        case resume, pause, next, previous, nowPlaying
        case volume(Int?, change: Int)
        case shuffle(Bool)
    }

    /// A short music request, or nil if it's anything else (that goes to Claude as usual).
    static func command(in request: String) -> Command? {
        // "play https://open.spotify.com/track/…" or the link alone: not a link mentioned in passing.
        if let uri = uri(in: request),
           request.range(of: #"^\W*((play|put on|open)\s+)?(\S*spotify\S*)\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .playLink(uri)
        }
        var text = request.lowercased()
            .replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\W*((hey|ok|okay|yo)\W+)?(joe\W+)?((can|could) you\W+|please\W+)*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\W+(please|thanks|thank you|joe)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // Other places to play things: not this.
        if text.range(of: #"\b(youtube|video|netflix|podcasts?|episode|apple music|in chrome|in vivaldi|movie|game|timer|alarm)\b"#, options: .regularExpression) != nil { return nil }
        text = text.replacingOccurrences(of: #"\s+(on|in) spotify$"#, with: "", options: .regularExpression)
        // Said a few ways in one breath ("pause it. pause the music. don't play it"): just pause.
        if text.count < 120, text.range(of: #"\b(pause|stop)\b[^.?!]{0,20}\b(it|this|that|the music|music|song|spotify|playing)\b"#, options: .regularExpression) != nil,
           text.range(of: #"\b(play|put on|resume)\s+(?!it\b)(?!music\b)\w"#, options: .regularExpression) == nil || text.contains("don't play") || text.contains("do not play") {
            return .pause
        }
        let exact: [(String, Command)] = [
            (#"^(pause|stop)( the| my| this| that)?( music| song| track| spotify| it| this| playing)?( song)?$"#, .pause),
            (#"^(resume|unpause|continue|keep playing|play|start)( the| my)?( music| song| spotify| it)?( again)?$"#, .resume),
            (#"^(skip|next)( this| the)?( song| track| one)?$|^(play the )?next (song|track)$"#, .next),
            (#"^(previous|go back|last|play the previous|play the last)( song| track| one)?$|^back( one)?$"#, .previous),
            (#"^(what'?s|what is) (this|playing|this song|the song|that song)( called| playing)?$|^what song is (this|playing)$"#, .nowPlaying),
            (#"^(shuffle|turn on shuffle|shuffle on)$"#, .shuffle(true)),
            (#"^(turn off shuffle|shuffle off|stop shuffling)$"#, .shuffle(false)),
            (#"^((turn|crank) (it|the music|the volume) up|louder|volume up)$"#, .volume(nil, change: 15)),
            (#"^((turn) (it|the music|the volume) down|quieter|softer|volume down)$"#, .volume(nil, change: -15)),
        ]
        for (pattern, command) in exact where text.range(of: pattern, options: .regularExpression) != nil { return command }
        if let match = text.range(of: #"^((set|turn|put) )?(the )?volume (up |down )?(to |at )?(\d{1,3})( percent|%)?$"#, options: .regularExpression) {
            let number = text[match].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            return Int(number).map { .volume(min($0, 100), change: 0) }
        }
        // "play X", "put on X", "play X on spotify", "play the album X", "play some Drake".
        if text.range(of: #"^(list|show|what are)( me)? (all )?my playlists$|^playlists$"#, options: .regularExpression) != nil { return .listPlaylists }
        if text.range(of: #"^(unlike|unsave|un-like) (this|the|that) (song|track)$|^remove (this|the|that)( song| track)? from my (liked songs|likes|library)$"#, options: .regularExpression) != nil { return .unlike(nil) }
        if text.hasPrefix("unlike spotify:track:") { return .unlike(String(request.split(separator: " ").last ?? "")) }
        // Their library: "play my liked songs", "shuffle my gym playlist", "like this song".
        if text.range(of: #"^(like|save|heart) (this|the|that) (song|track)$|^add (this|the|that)( song| track)? to my (liked songs|likes|library|liked)$"#,
                      options: .regularExpression) != nil { return .like }
        let shuffle = text.hasPrefix("shuffle ")
        if text.range(of: #"^(play|shuffle|put on) (my )?(liked songs|liked|likes|saved songs|favou?rites|library|music library)$"#,
                      options: .regularExpression) != nil { return .likedSongs(shuffle: shuffle) }
        for pattern in [#"^(?:play|shuffle|put on) my (.+?) playlist$"#, #"^(?:play|shuffle|put on) my playlist (?:called )?(.+)$"#, #"^(?:play|shuffle|put on) my (.+)$"#] {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range(at: 1), in: text) {
                return .myPlaylist(String(text[range]), shuffle: shuffle)
            }
        }
        guard let verb = text.range(of: #"^(play|put on|queue up|blast)\s+"#, options: .regularExpression) else { return nil }
        text = String(text[verb.upperBound...]).replacingOccurrences(of: #"\s+(on|in|from) spotify$"#, with: "", options: .regularExpression)
        var kind: Kind?
        for (pattern, found) in [(#"^(the )?album\s+"#, Kind.album), (#"^(the )?playlist\s+"#, .playlist),
                                 (#"^(some|songs by|music by|anything by)\s+"#, .artist)] {
            if let range = text.range(of: pattern, options: .regularExpression) {
                kind = found
                text = String(text[range.upperBound...])
            }
        }
        text = text.replacingOccurrences(of: #"^(the song|the track|song)\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+by\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // Too vague for a search ("play something chill"): Claude can pick.
        guard text.count >= 2, text.range(of: #"^(something|anything|music|a song|some music)\b"#, options: .regularExpression) == nil else { return nil }
        return .play(text, kind)
    }

    /// "spotify:track:…" or "https://open.spotify.com/intl-de/album/…" in a request, as a URI. Read
    /// from the request as said: the IDs are case-sensitive.
    static func uri(in request: String) -> String? {
        let pattern = #"spotify:(track|album|artist|playlist):([A-Za-z0-9]{22})|open\.spotify\.com/(?:intl-[a-z-]+/)?(track|album|artist|playlist)/([A-Za-z0-9]{22})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: request, range: NSRange(request.startIndex..., in: request)) else { return nil }
        let part = { (i: Int) in Range(match.range(at: i), in: request).map { String(request[$0]) } }
        guard let kind = part(1) ?? part(3), let id = part(2) ?? part(4) else { return nil }
        return "spotify:\(kind):\(id)"
    }

    /// Whether this Mac can search Spotify: the developer's own keys, or a signed-in account. Other
    /// Macs can't since Spotify's 2026 limits (5 allow-listed users per app in development mode).
    static var canSearch: Bool { keys != nil || Account.isConnected }

    /// A command to carry out at once, without Claude. "Play X" goes to Claude instead when this Mac
    /// can't search: Claude finds the song's open.spotify.com link on the web and plays that.
    static func quick(in request: String) -> Command? {
        guard let command = command(in: request) else { return nil }
        if case .play = command, !canSearch { return nil }
        return command
    }

    // MARK: - Doing it

    /// Carries out a command and says what happened, in a few words.
    /// When music was last controlled on purpose (also by the assistant, through `Joe --spotify`,
    /// in another process): the app then leaves the music as it is instead of resuming it.
    static var lastCommand: Date {
        Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "spotifyLastCommand"))
    }

    static func run(_ command: Command) -> String {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "spotifyLastCommand")
        switch command {
        case let .likedSongs(shuffle): return Account.playLiked(shuffle: shuffle)
        case let .myPlaylist(name, shuffle): return Account.playPlaylist(named: name, shuffle: shuffle)
        case .like: return Account.likeCurrent()
        case .listPlaylists: return Account.listPlaylists()
        case let .unlike(uri): return Account.unlike(uri)
        case let .playLink(uri):
            guard script("play track \"\(uri)\"") != nil || (launch() && script("play track \"\(uri)\"") != nil) else {
                return "Spotify didn't respond."
            }
            return "▶ " + (current() ?? "Playing")
        case let .play(query, kind):
            guard let found = search(query, kind: kind) else {
                return canSearch ? "Couldn't find “\(query)” on Spotify."
                    : "Can't search Spotify on this Mac. Find its open.spotify.com link and play that instead."
            }
            guard script("play track \"\(found.uri)\"") != nil || (launch() && script("play track \"\(found.uri)\"") != nil) else {
                return "Found \(found.title), but Spotify didn't respond."
            }
            return "▶ \(found.title)"
        case .resume: return script("play") != nil ? "▶ Playing" : "Spotify didn't respond."
        case .pause: return script("pause") != nil ? "Paused" : "Spotify didn't respond."
        case .next:
            _ = script("next track")
            return "⏭ " + (current() ?? "Next")
        case .previous:
            _ = script("previous track")
            return "⏮ " + (current() ?? "Previous")
        case .nowPlaying: return current().map { "Playing \($0)" } ?? "Nothing's playing."
        case let .shuffle(on):
            _ = script("set shuffling to \(on)")
            return on ? "Shuffle on" : "Shuffle off"
        case let .volume(level, change):
            let now = script("sound volume").flatMap { Int($0) } ?? 50
            let target = max(0, min(100, level ?? now + change))
            _ = script("set sound volume to \(target)")
            return "Volume \(target)%"
        }
    }

    /// "Fly Me To The Moon — Frank Sinatra", or nil when nothing's playing.
    static func current() -> String? {
        Thread.sleep(forTimeInterval: 0.3) // after a skip, the new track takes a moment
        guard let name = script("name of current track"), !name.isEmpty else { return nil }
        let artist = script("artist of current track") ?? ""
        return artist.isEmpty ? name : "\(name) — \(artist)"
    }

    /// Runs `tell application "Spotify" to …`, or nil if Spotify isn't open or refused.
    @discardableResult
    fileprivate static func script(_ line: String) -> String? {
        if !Thread.isMainThread { return DispatchQueue.main.sync { script(line) } } // AppleScript wants the main thread
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first != nil else { return nil }
        var error: NSDictionary?
        let result = NSAppleScript(source: "tell application \"Spotify\" to \(line)")?.executeAndReturnError(&error)
        return error == nil ? (result?.stringValue ?? "") : nil
    }

    /// Opens Spotify (in the background) and waits until it can take commands.
    fileprivate static func launch() -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.3)
            if script("player state") != nil { Thread.sleep(forTimeInterval: 1); return true }
        }
        return false
    }

    // MARK: - Finding it (Web API)

    /// The keys and the login, in a file only this Mac account can read (Spotify.json, mode 600).
    /// Not the Keychain: macOS asks for the password again each time the app is rebuilt.
    fileprivate static let secretsFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Shhh/Spotify.json")

    private static var secrets: [String: String] {
        (try? Data(contentsOf: secretsFile)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    fileprivate static func read(_ account: String) -> String? {
        secrets[account]
    }

    fileprivate static func store(_ value: String, as account: String) {
        var all = secrets
        all[account] = value
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(at: secretsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: secretsFile.path, contents: data, attributes: [.posixPermissions: 0o600])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretsFile.path)
    }

    fileprivate static func forget(_ account: String) {
        var all = secrets
        all[account] = nil
        guard let data = try? JSONEncoder().encode(all) else { return }
        FileManager.default.createFile(atPath: secretsFile.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    fileprivate static var keys: (id: String, secret: String)? {
        guard let id = clientID, let secret = read("client-secret") else { return nil }
        return (id, secret)
    }

    /// Joe's Spotify app: from this Mac's Spotify.json, or built into the app (the login uses PKCE,
    /// so the ID alone is enough and every Mac can connect; the secret never leaves the developer's).
    fileprivate static var clientID: String? {
        read("client-id") ?? Bundle.main.url(forResource: "SpotifyClientID", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var token: (value: String, expires: Date)?

    private static func accessToken() -> String? {
        if let token, token.expires > Date() { return token.value }
        guard let keys, let url = URL(string: "https://accounts.spotify.com/api/token") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Basic " + Data("\(keys.id):\(keys.secret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=client_credentials".utf8)
        guard let json = fetch(request), let value = json["access_token"] as? String else { return nil }
        token = (value, Date().addingTimeInterval(Double(json["expires_in"] as? Int ?? 3600) - 60))
        return value
    }

    /// The best match: for a plain request, the top song, unless an artist matches the words exactly.
    static func search(_ query: String, kind: Kind?) -> (uri: String, title: String)? {
        guard let token = accessToken() ?? Account.userToken() else { return nil }
        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        let types = kind.map { [$0] } ?? [.track, .artist]
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "type", value: types.map(\.rawValue).joined(separator: ",")),
                                 URLQueryItem(name: "limit", value: "5")]
        var request = URLRequest(url: components.url!, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let json = fetch(request) else { return nil }
        func first(_ kind: Kind) -> [String: Any]? {
            ((json[kind.rawValue + "s"] as? [String: Any])?["items"] as? [Any])?.compactMap { $0 as? [String: Any] }.first
        }
        if kind == nil, let artist = first(.artist), (artist["name"] as? String)?.lowercased() == query.lowercased(),
           let uri = artist["uri"] as? String {
            return (uri, "\(artist["name"] as? String ?? query) (top songs)")
        }
        guard let item = first(kind ?? .track), let uri = item["uri"] as? String else { return nil }
        let name = item["name"] as? String ?? query
        let by = ((item["artists"] as? [[String: Any]])?.first?["name"] as? String)
            ?? ((item["owner"] as? [String: Any])?["display_name"] as? String)
        return (uri, by.map { "\(name) — \($0)" } ?? name)
    }

    fileprivate static func fetch(_ request: URLRequest) -> [String: Any]? {
        let done = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            result = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 12)
        return result
    }

    // MARK: - Their account (option C)

    /// Their own Spotify: liked songs, playlists, liking a song. One login (`Shhh --spotify-login`)
    /// gives a refresh token, kept with the keys in Spotify.json.
    enum Account {
        static let redirect = "http://127.0.0.1:8888/callback"
        static let scopes = "user-library-read user-library-modify playlist-read-private playlist-read-collaborative "
            + "playlist-modify-private user-read-private user-read-playback-state user-read-currently-playing"

        static var isConnected: Bool { Spotify.read("refresh-token") != nil }

        // MARK: Login

        /// Opens Spotify's consent page in the browser and waits (up to three minutes) for the
        /// redirect back to 127.0.0.1:8888, then keeps the refresh token.
        static func login() -> String {
            guard let id = Spotify.clientID else { return "This copy of Joe has no Spotify app ID built in." }
            let verifier = (0..<64).map { _ in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".randomElement()! }.map(String.init).joined()
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let state = UUID().uuidString
            var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
            components.queryItems = [
                .init(name: "client_id", value: id), .init(name: "response_type", value: "code"),
                .init(name: "redirect_uri", value: redirect), .init(name: "scope", value: scopes),
                .init(name: "code_challenge_method", value: "S256"), .init(name: "code_challenge", value: challenge),
                .init(name: "state", value: state),
            ]
            let answer = waitForCode(state: state, opening: components.url!)
            guard let code = answer.code else { return answer.problem }
            var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!, timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = form(["grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
                                     "client_id": id, "code_verifier": verifier])
            guard let json = Spotify.fetch(request), let refresh = json["refresh_token"] as? String else {
                return "Spotify didn't accept the login. Try again."
            }
            Spotify.store(refresh, as: "refresh-token")
            if let access = json["access_token"] as? String {
                token = (access, Date().addingTimeInterval(Double(json["expires_in"] as? Int ?? 3600) - 60))
            }
            var status = 0
            let me = api("GET", "/me", status: &status)
            if status == 403 { // signed in, but not one of the app's allow-listed users
                Spotify.forget("refresh-token")
                token = nil
                return "Spotify signed you in, but this account isn't on Joe's Spotify tester list yet, so liked songs "
                    + "and playlists can't work. Playing songs still works. Ask Joe's developer to add your Spotify email."
            }
            let name = (me?["display_name"] as? String).map { " as \($0)" } ?? ""
            return "Connected to Spotify\(name). Your library works now."
        }

        private static func form(_ fields: [String: String]) -> Data {
            var components = URLComponents()
            components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
            return Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        }

        /// A tiny one-shot web server on 127.0.0.1:8888 for Spotify's redirect.
        /// The sign-in waiting for its answer: a second click closes it and starts again.
        nonisolated(unsafe) private static var waiting: (listener: NWListener, done: DispatchSemaphore)?

        private static func waitForCode(state: String, opening url: URL) -> (code: String?, problem: String) {
            if let waiting { waiting.listener.cancel(); waiting.done.signal() }
            Thread.sleep(forTimeInterval: 0.3) // let the port go
            guard let listener = try? NWListener(using: .tcp, on: 8888) else {
                return (nil, "Something else on this Mac is using port 8888, which Spotify's sign-in needs. Quit it and try again.")
            }
            var code: String?
            let done = DispatchSemaphore(value: 0)
            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                    let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    let items = URLComponents(string: "http://127.0.0.1" + path)?.queryItems ?? []
                    let found = items.first { $0.name == "code" }?.value
                    let ok = found != nil && items.first { $0.name == "state" }?.value == state
                    let page = ok ? "Spotify is connected to Joe. You can close this tab." : "Spotify didn't connect. You can close this tab and try again."
                    let body = "<html><body style=\"font:16px -apple-system;padding:40px\">\(page)</body></html>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                        if path.hasPrefix("/callback") {
                            if ok { code = found }
                            done.signal()
                        }
                    })
                }
            }
            listener.start(queue: .global())
            waiting = (listener, done)
            NSWorkspace.shared.open(url)
            _ = done.wait(timeout: .now() + 180)
            listener.cancel()
            waiting = nil
            return (code, "No answer from Spotify's sign-in page within three minutes. Click Connect to try again.")
        }

        // MARK: Calls

        private static var token: (value: String, expires: Date)?

        /// The signed-in user's token (also used for search when there's no app secret on this Mac).
        static func userToken() -> String? { accessToken() }

        private static func accessToken() -> String? {
            if let token, token.expires > Date() { return token.value }
            guard let id = Spotify.clientID, let refresh = Spotify.read("refresh-token") else { return nil }
            var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!, timeoutInterval: 10)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = form(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": id])
            guard let json = Spotify.fetch(request), let value = json["access_token"] as? String else { return nil }
            if let rotated = json["refresh_token"] as? String { Spotify.store(rotated, as: "refresh-token") }
            token = (value, Date().addingTimeInterval(Double(json["expires_in"] as? Int ?? 3600) - 60))
            return value
        }

        /// A Web API call as the user. Returns the JSON (empty for "no content"), or nil on failure;
        /// `status` gets the HTTP status.
        @discardableResult
        static func api(_ method: String, _ path: String, body: [String: Any]? = nil, status: UnsafeMutablePointer<Int>? = nil) -> [String: Any]? {
            guard let token = accessToken(), let url = URL(string: "https://api.spotify.com/v1" + path) else { return nil }
            var request = URLRequest(url: url, timeoutInterval: 12)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            } else if method != "GET" {
                request.setValue("0", forHTTPHeaderField: "Content-Length")
            }
            let done = DispatchSemaphore(value: 0)
            var result: [String: Any]?
            URLSession.shared.dataTask(with: request) { data, response, _ in
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                status?.pointee = code
                if (200..<300).contains(code) {
                    result = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                }
                done.signal()
            }.resume()
            _ = done.wait(timeout: .now() + 14)
            return result
        }

        private static let notConnected = "Spotify isn't connected to your account yet: connect it on the Spotify page of Joe's dashboard."

        // MARK: Library

        /// Liked Songs, played as a private playlist that mirrors them ("Liked Songs (Joe)"): Spotify
        /// on this Mac won't start the Liked Songs collection when asked from outside the app, but
        /// plays playlists fine. The mirror catches up whenever the likes have changed.
        static func playLiked(shuffle: Bool) -> String {
            guard isConnected else { return notConnected }
            guard let uri = likedMirror() else { return "Couldn't set up your liked songs (try Joe --spotify-login again)." }
            guard Spotify.script("play track \"\(uri)\"") != nil || (Spotify.launch() && Spotify.script("play track \"\(uri)\"") != nil) else {
                return "Spotify didn't respond."
            }
            // Shuffle once it's playing (Spotify resets it when a playlist starts), then jump off the newest.
            _ = Spotify.script("set shuffling to \(shuffle)")
            if shuffle {
                Thread.sleep(forTimeInterval: 0.4)
                _ = Spotify.script("next track")
            }
            return "▶ Your liked songs\(shuffle ? ", shuffled" : "")"
        }

        private static let mirrorName = "Liked Songs (Joe)"

        /// The mirror playlist's URI, brought up to date with the likes first if they've changed.
        private static func likedMirror() -> String? {
            guard let newest = api("GET", "/me/tracks?limit=1") else { return nil }
            let total = newest["total"] as? Int ?? 0
            let newestID = ((newest["items"] as? [[String: Any]])?.first?["track"] as? [String: Any])?["id"] as? String ?? ""
            let defaults = UserDefaults.standard
            var playlist = defaults.string(forKey: "spotifyLikedMirror")
            // Still there? (They may have deleted it.)
            if let id = playlist, api("GET", "/playlists/\(id)?fields=id") == nil { playlist = nil }
            if playlist == nil {
                guard let made = api("POST", "/me/playlists", body: ["name": mirrorName, "public": false,
                                    "description": "Your Liked Songs, kept in step by Joe so he can play them."]),
                      let id = made["id"] as? String else { return nil }
                playlist = id
                defaults.set(id, forKey: "spotifyLikedMirror")
                defaults.removeObject(forKey: "spotifyLikedMirrorState")
            }
            guard let id = playlist else { return nil }
            let state = "\(total):\(newestID)"
            if defaults.string(forKey: "spotifyLikedMirrorState") != state {
                // Rebuild it: all the likes, newest first, 50 read and 100 written at a time.
                var uris: [String] = []
                var offset = 0
                while offset < total, let page = api("GET", "/me/tracks?limit=50&offset=\(offset)") {
                    uris += (page["items"] as? [[String: Any]] ?? []).compactMap { ($0["track"] as? [String: Any])?["uri"] as? String }
                    offset += 50
                }
                let batches = stride(from: 0, to: uris.count, by: 100).map { Array(uris[$0..<min($0 + 100, uris.count)]) }
                // (Spotify's current endpoints: /me/playlists to make it, /playlists/…/items to fill it.)
                guard api("PUT", "/playlists/\(id)/items", body: ["uris": batches.first ?? []]) != nil else { return nil }
                for batch in batches.dropFirst() { api("POST", "/playlists/\(id)/items", body: ["uris": batch]) }
                defaults.set(state, forKey: "spotifyLikedMirrorState")
            }
            return "spotify:playlist:\(id)"
        }

        /// Their playlists (up to 300).
        private static func playlists() -> [[String: Any]] {
            var playlists: [[String: Any]] = []
            var path: String? = "/me/playlists?limit=50"
            while let next = path, playlists.count < 300, let page = api("GET", next) {
                playlists += page["items"] as? [[String: Any]] ?? []
                path = (page["next"] as? String).map { $0.replacingOccurrences(of: "https://api.spotify.com/v1", with: "") }
            }
            return playlists
        }

        /// "Pick something for studying": their playlists by name and size, for the assistant to choose from.
        static func listPlaylists() -> String {
            guard isConnected else { return notConnected }
            let names = playlists().compactMap { item -> String? in
                guard let name = item["name"] as? String, name != mirrorName else { return nil }
                let count = ((item["items"] ?? item["tracks"]) as? [String: Any])?["total"] as? Int
                return count.map { "\(name) (\($0))" } ?? name
            }
            return names.isEmpty ? "No playlists." : "Their playlists (and liked songs): " + names.joined(separator: "; ")
        }

        static func playPlaylist(named name: String, shuffle: Bool) -> String {
            guard isConnected else { return notConnected }
            var playlists = playlists()
            let wanted = name.lowercased().replacingOccurrences(of: #"^the "#, with: "", options: .regularExpression)
            playlists.removeAll { ($0["name"] as? String) == mirrorName }
            let names = playlists.map { (($0["name"] as? String) ?? "").lowercased() }
            guard let index = names.firstIndex(of: wanted) ?? names.firstIndex(where: { $0.contains(wanted) || wanted.contains($0) && !$0.isEmpty })
                    ?? names.firstIndex(where: { name in wanted.split(separator: " ").allSatisfy { name.contains($0) } }),
                  let uri = playlists[index]["uri"] as? String else {
                return "You don't have a playlist called “\(name)”."
            }
            _ = Spotify.script("set shuffling to \(shuffle)")
            guard Spotify.script("play track \"\(uri)\"") != nil || (Spotify.launch() && Spotify.script("play track \"\(uri)\"") != nil) else {
                return "Spotify didn't respond."
            }
            return "▶ \(playlists[index]["name"] as? String ?? name)\(shuffle ? ", shuffled" : "")"
        }

        /// Takes a song out of their liked songs (the playing one, or a given spotify:track: URI).
        static func unlike(_ uri: String?) -> String {
            guard isConnected else { return notConnected }
            guard let uri = uri ?? Spotify.script("id of current track"), uri.hasPrefix("spotify:track:") else { return "Nothing to unlike." }
            var code = 0
            api("DELETE", "/me/library?uris=\(uri)", status: &code)
            return (200..<300).contains(code) ? "Removed it from your liked songs" : "Couldn't remove it."
        }

        static func likeCurrent() -> String {
            guard isConnected else { return notConnected }
            guard let uri = Spotify.script("id of current track"), let id = uri.split(separator: ":").last else {
                return "Nothing's playing."
            }
            var code = 0
            api("PUT", "/me/library?uris=spotify:track:\(id)", status: &code) // Spotify's current "save to library"
            if (200..<300).contains(code) { UndoJournal.add(["liked", "spotify:track:\(id)"]) }
            return (200..<300).contains(code) ? "Saved \(Spotify.script("name of current track") ?? "it") to your liked songs" : "Couldn't save it."
        }
    }
}
