//
//  SearchManager.swift
//  EMHenTai
//
//  Created by yuman on 2022/1/14.
//

import Alamofire
import Combine
import Foundation

/// The manager itself lives on the main actor: it only tracks the in-flight task and publishes
/// events the UI consumes. The request work stays in a `nonisolated` method.
@MainActor
final class SearchManager {
    enum SearchEvent {
        case start(info: SearchInfo)
        case finish(info: SearchInfo, result: Result<[Book], SearchManager.Error>)
    }
    
    enum Error: Swift.Error {
        /// Banner text the site serves when the IP is hard-banned.
        static let ipBanner = "Your IP address has been temporarily banned for excessive pageloads"

        /// Transport/parse failure that is not otherwise classified. `detail` carries the raw
        /// underlying error (e.g. "code -1006") so a user screenshot pinpoints the real cause.
        case netError(detail: String?)
        case ipError
        /// The site host itself is unreachable from this network (missing proxy rule / GFW).
        case unreachable
        /// Cloudflare refused the request outright (403).
        case blocked
        /// Origin or proxy answered 5xx.
        case serverError
        /// ExHentai bounced us off exhentai.org: igneous credential missing or no site access.
        case exDenied
    }
    
    static let shared = SearchManager()
    private init() {}
    
    private var currentTask: Task<Void, Never>?
    
    let eventSubject = PassthroughSubject<SearchEvent, Never>()
    
    func searchWith(info: SearchInfo) {
        guard info.lastGid.isEmpty || currentTask == nil else {
            return
        }
        
        currentTask?.cancel()
        
        currentTask = Task {
            guard !Task.isCancelled else { return }
            
            self.eventSubject.send(.start(info: info))
            
            let result = await self.startSearchWith(info: info)
            
            guard !Task.isCancelled else { return }
            
            self.eventSubject.send(.finish(info: info, result: result))
            
            self.currentTask = nil
        }
    }
    
    private nonisolated func startSearchWith(info: SearchInfo) async -> Result<[Book], Error> {
        let pageRequest = emSession.request(info.requestString, interceptor: RetryPolicy())
        let pageResult = await pageRequest.serializingString().result
        let value: String
        switch pageResult {
        case .success(let v): value = v
        case .failure(let e): return .failure(Self.classify(e))
        }
        // ExHentai bounces cookieless visitors (missing igneous) to the forums' sad-panda
        // page: that is an access problem, not "no search results".
        if info.source == .ExHentai,
           let host = pageRequest.response?.url?.host,
           !host.hasSuffix("exhentai.org") {
            return .failure(.exDenied)
        }
        if let statusCode = pageRequest.response?.statusCode, statusCode >= 500 {
            return .failure(.serverError)
        }
        guard !value.contains(Error.ipBanner) else { return .failure(.ipError) }
        
        let ids = value
            .allSubString(of: info.source.rawValue + "g/", endCharater: "/", count: 2)
            .map { $0.split(separator: "/") }
            .filter { $0.count == 2 }
        guard !ids.isEmpty else { return .success([]) }
        
        let apiRequest = emSession
            .request(
                info.source.rawValue + "api.php",
                method: .post,
                parameters: ["method": "gdata", "gidlist": ids],
                encoding: JSONEncoding.default,
                interceptor: RetryPolicy()
            )
        let apiResult = await apiRequest.serializingDecodable(Gmetadata.self).result
        let metadata: Gmetadata
        switch apiResult {
        case .success(let v): metadata = v
        case .failure(let e):
            if let statusCode = apiRequest.response?.statusCode, statusCode >= 500 {
                return .failure(.serverError)
            }
            return .failure(Self.classify(e))
        }
        
        return .success((metadata.gmetadata ?? []).compactMap({ Book($0) }))
    }
    
    /// Map a transport failure to a user-actionable error: distinguishing "host unreachable
    /// from this network" (missing proxy rule) from a Cloudflare refusal (403) from plain
    /// network flakiness.
    nonisolated static func classify(_ error: AFError) -> Error {
        if let code = error.responseCode, code == 403 || code == 429 { return .blocked }
        if let urlError = error.underlyingError as? URLError {
            switch urlError.code {
            case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .networkConnectionLost,
                 .notConnectedToInternet, .timedOut, .secureConnectionFailed, .serverCertificateUntrusted:
                return .unreachable
            default:
                return .netError(detail: "code \(urlError.code.rawValue)")
            }
        }
        if case let .responseSerializationFailed(reason) = error,
           case let .decodingFailed(decodingError) = reason {
            return .netError(detail: brief(String(describing: decodingError)))
        }
        return .netError(detail: error.underlyingError.map { brief(String(describing: $0)) })
    }

    private static func brief(_ text: String) -> String {
        text.count > 120 ? String(text.prefix(120)) + "…" : text
    }
}

private struct Gmetadata: Decodable {
    let gmetadata: [BookDto]?
}

private struct BookDto: Decodable {
    let gid: Int?
    let title: String?
    let title_jpn: String?
    let category: String?
    let thumb: String?
    let filecount: String?
    let tags: [String?]?
    let token: String?
    let rating: String?
}

private extension Book {
    init?(_ dto: BookDto) {
        guard let gid = dto.gid else { return nil }
        self.init(
            gid: gid,
            title: dto.title,
            titleJpn: dto.title_jpn,
            category: dto.category,
            thumb: dto.thumb,
            fileCount: Int(dto.filecount ?? "0") ?? 0,
            tags: (dto.tags ?? []).compactMap({ $0 }),
            token: dto.token,
            rating: dto.rating
        )
    }
}
