import Foundation

@MainActor
final class LyricsLookup {
    struct Request: Hashable {
        let title: String
        let artist: String
        let album: String
        let seconds: Int?

        init?(track: PlayerTrack) {
            title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
            artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !artist.isEmpty else { return nil }
            album = track.album.trimmingCharacters(in: .whitespacesAndNewlines)
            if let rounded = track.duration?.rounded(), (1...3600).contains(rounded) {
                seconds = Int(rounded)
            } else {
                seconds = nil
            }
        }

        fileprivate var url: URL? {
            var fields = [URLQueryItem(name: "track_name", value: title),
                          URLQueryItem(name: "artist_name", value: artist)]
            if !album.isEmpty { fields.append(URLQueryItem(name: "album_name", value: album)) }
            if let seconds { fields.append(URLQueryItem(name: "duration", value: String(seconds))) }
            var components = URLComponents()
            components.scheme = "https"
            components.host = "lrclib.net"
            components.path = "/api/get"
            components.queryItems = fields
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            return components.url
        }
    }

    enum State: Equatable {
        case loading, found(String), instrumental, missing, failed
    }

    private struct Result {
        let request: Request
        let state: State
    }

    private var current: Result?
    private var recent: [Result] = []
    private var retryAfter = Date.distantPast
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 18
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpAdditionalHeaders = ["User-Agent": "NotchMusic/1.0 (personal macOS app)"]
        return URLSession(configuration: config)
    }()

    func state(for request: Request) -> State {
        if current?.request == request, let state = current?.state { return state }
        return recent.last { $0.request == request }?.state ?? .loading
    }

    func load(_ request: Request) async {
        if let hit = recent.last(where: { $0.request == request }) {
            current = hit
            return
        }
        guard Date() >= retryAfter, let url = request.url else {
            current = Result(request: request, state: .failed)
            return
        }
        current = Result(request: request, state: .loading)
        do {
            let (data, response) = try await session.data(from: url)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            let state: State
            switch http.statusCode {
            case 200:
                state = try JSONDecoder().decode(Record.self, from: data).state
            case 404:
                state = .missing
            case 429, 503:
                let delay = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 10
                retryAfter = Date().addingTimeInterval(max(1, delay) + Double.random(in: 0...1))
                throw URLError(.resourceUnavailable)
            default:
                throw URLError(.badServerResponse)
            }
            let result = Result(request: request, state: state)
            recent.removeAll { $0.request == request }
            if recent.count >= 6 { recent.removeFirst() }
            recent.append(result)
            current = result
        } catch {
            if !Task.isCancelled { current = Result(request: request, state: .failed) }
        }
    }

    private struct Record: Decodable {
        let instrumental: Bool
        let plainLyrics: String?
        let syncedLyrics: String?

        var state: State {
            if instrumental { return .instrumental }
            if let plain = plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !plain.isEmpty {
                return .found(plain)
            }
            guard let syncedLyrics else { return .missing }
            let text = syncedLyrics
                .replacingOccurrences(of: #"\[\d+:\d+(?:[.:]\d+)?\]"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .missing : .found(text)
        }
    }
}
