//
//  SearchManager.swift
//  EMHenTai
//
//  Created by yuman on 2022/1/14.
//

import Alamofire
import Combine

/// The manager itself lives on the main actor: it only tracks the in-flight task and publishes
/// events the UI consumes. The request work stays in a `nonisolated` method.
@MainActor
final class SearchManager {
    enum SearchEvent {
        case start(info: SearchInfo)
        case finish(info: SearchInfo, result: Result<[Book], SearchManager.Error>)
    }
    
    enum Error: String, Swift.Error {
        case netError
        case ipError = "Your IP address has been temporarily banned for excessive pageloads"
        /// The site host itself is unreachable from this network (missing proxy rule / GFW).
        case unreachable
        /// Cloudflare refused the request outright (403).
        case blocked
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
        let page = await emSession.request(info.requestString, interceptor: RetryPolicy()).serializingString().result
        guard let value = try? page.get() else {
            return .failure(Self.classify(page.failure!))
        }
        guard !value.contains(Error.ipError.rawValue) else { return .failure(.ipError) }
        
        let ids = value
            .allSubString(of: info.source.rawValue + "g/", endCharater: "/", count: 2)
            .map { $0.split(separator: "/") }
            .filter { $0.count == 2 }
        guard !ids.isEmpty else { return .success([]) }
        
        let api = await emSession
            .request(
                info.source.rawValue + "api.php",
                method: .post,
                parameters: ["method": "gdata", "gidlist": ids],
                encoding: JSONEncoding.default,
                interceptor: RetryPolicy()
            )
            .serializingDecodable(Gmetadata.self)
            .result
        guard let value = try? api.get() else { return .failure(Self.classify(api.failure!)) }
        
        return .success((value.gmetadata ?? []).compactMap({ Book($0) }))
    }
    
    /// Map a transport failure to a user-actionable error: distinguishing "host unreachable
    /// from this network" (missing proxy rule) from a Cloudflare refusal (403) from plain
    /// network flakiness.
    nonisolated static func classify(_ error: AFError) -> Error {
        if let code = error.responseCode, code == 403 || code == 429 { return .blocked }
        if let urlError = error.underlyingError as? URLError {
            switch urlError.code {
            case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .timedOut:
                return .unreachable
            default:
                break
            }
        }
        return .netError
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
