//
//  DownloadManager.swift
//  EMHenTai
//
//  Created by yuman on 2022/1/14.
//

import Alamofire
import Combine
import Foundation
import Kingfisher

/// The manager itself lives on the main actor: it only bookkeeps running tasks and publishes
/// events the UI consumes. The networking and file work stays in `nonisolated` methods.
@MainActor
final class DownloadManager {
    // 整个本子的下载状态
    enum State {
        case before
        case ing
        case suspend
        case finish
    }
    
    static let shared = DownloadManager()
    
    let downloadStateChangedSubject = PassthroughSubject<(book: Book, state: State), Never>()
    let downloadPageProgressSubject = PassthroughSubject<(book: Book, index: Int, progress: Double), Never>()
    let downloadPageSuccessSubject = PassthroughSubject<(book: Book, index: Int), Never>()
    
    private init() {}
    private let groupTotalImgNum = 40
    private var taskMap = [Int: Task<Void, Never>]()
    
    func download(_ book: Book) {
        guard case let state = downloadState(of: book), state != .ing && state != .finish else { return }
        
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: book.folderPath), withIntermediateDirectories: true)
        
        taskMap[book.gid] = Task {
            await self.startDownload(book)
            self.taskMap[book.gid] = nil
            self.downloadStateChangedSubject.send((book, self.downloadState(of: book)))
        }
        
        downloadStateChangedSubject.send((book, .ing))
    }
    
    func suspend(_ book: Book) {
        taskMap[book.gid]?.cancel()
        taskMap[book.gid] = nil
        downloadStateChangedSubject.send((book, .suspend))
    }
    
    func remove(_ book: Book) {
        taskMap[book.gid]?.cancel()
        taskMap[book.gid] = nil
        Task {
            await Self.removeFolder(of: book)
            self.downloadStateChangedSubject.send((book, .before))
        }
    }
    
    /// Pass `downloadedImgCount` when the caller already enumerated the folder, so a single
    /// `updateProgress` pass doesn't walk the same directory several times on the main thread.
    func downloadState(of book: Book, downloadedImgCount: Int? = nil) -> State {
        let downloadedImgCount = downloadedImgCount ?? book.downloadedImgCount
        if downloadedImgCount == book.fileCount + 1 {
            return .finish
        } else if taskMap[book.gid] != nil {
            return .ing
        } else {
            return downloadedImgCount == 0 ? .before : .suspend
        }
    }
    
    private nonisolated static func removeFolder(of book: Book) async {
        try? FileManager.default.removeItem(atPath: book.folderPath)
    }
    
    private nonisolated func startDownload(_ book: Book) async {
        if !FileManager.default.fileExists(atPath: book.coverImagePath), let thumb = book.thumb {
            let from = KingfisherManager.shared.cache.diskStorage.cacheFileURL(forKey: thumb)
            if FileManager.default.fileExists(atPath: from.path) {
                let to = URL(fileURLWithPath: book.coverImagePath)
                try? FileManager.default.copyItem(at: from, to: to)
            } else {
                _ = try? await emSession
                    .download(thumb, interceptor: RetryPolicy.downloadRetryPolicy, to: { _, _ in (URL(fileURLWithPath: book.coverImagePath), []) })
                    .serializingDownload(using: URLResponseSerializer())
                    .value
            }
        }
        
        guard !Task.isCancelled else { return }
        
        let urlStream = AsyncStream<String> { continuation in
            Task {
                await withTaskGroup(of: Void.self, body: { group in
                    let groupNum = book.fileCount / self.groupTotalImgNum + (book.fileCount % self.groupTotalImgNum == 0 ? 0 : 1)
                    for groupIndex in 0 ..< groupNum {
                        guard self.checkGroupNeedRequest(of: book, groupIndex: groupIndex) else { continue }
                        group.addTask {
                            let url = book.currentWebURLString + (groupIndex > 0 ? "?p=\(groupIndex)" : "") + "/?nw=session"
                            guard let value = try? await emSession.request(url, interceptor: RetryPolicy.downloadRetryPolicy).serializingString().value else { return }
                            guard !Task.isCancelled else { return }
                            let baseURL = SearchInfo.currentSource.rawValue + "s/"
                            value.allSubString(of: baseURL, endCharater: "\"").forEach { continuation.yield(baseURL + $0) }
                        }
                        await group.waitForAll()
                        guard !Task.isCancelled else { return }
                    }
                })
                continuation.finish()
            }
        }
        
        await withTaskGroup(of: Void.self, body: { group in
            for await url in urlStream {
                guard !Task.isCancelled else { return }
                let imgIndex = (url.split(separator: "-").last.flatMap({ Int($0) }) ?? 1) - 1
                guard !FileManager.default.fileExists(atPath: book.imagePath(at: imgIndex)) else { continue }
                
                group.addTask {
                    guard let html = try? await emSession.request(url, interceptor: RetryPolicy.downloadRetryPolicy).serializingString().value else { return }
                    guard !Task.isCancelled else { return }
                    guard let imgURL = html.allSubString(of: "<img id=\"img\" src=\"", endCharater: "\"").first else { return }
                    
                    guard let p = try? await emSession
                        .download(imgURL, interceptor: RetryPolicy.downloadRetryPolicy, to: { _, _ in (URL(fileURLWithPath: book.imagePath(at: imgIndex)), []) })
                        .downloadProgress(queue: .main, closure: { progress in
                            // Alamofire delivers this on DispatchQueue.main, which is the main actor's executor.
                            let fractionCompleted = progress.fractionCompleted
                            MainActor.assumeIsolated {
                                self.downloadPageProgressSubject.send((book, imgIndex, fractionCompleted))
                            }
                        })
                            .serializingDownload(using: URLResponseSerializer())
                            .value,
                            FileManager.default.fileExists(atPath: p.path)
                    else { return }
                    
                    await MainActor.run {
                        self.downloadPageSuccessSubject.send((book, imgIndex))
                    }
                }
            }
        })
    }
    
    private nonisolated func checkGroupNeedRequest(of book: Book, groupIndex: Int) -> Bool {
        for index in 0 ..< groupTotalImgNum {
            guard case let realIndex = groupIndex * groupTotalImgNum + index, realIndex < book.fileCount else {
                break
            }
            if !FileManager.default.fileExists(atPath: book.imagePath(at: realIndex)) {
                return true
            }
        }
        return false
    }
}

private extension RetryPolicy {
    static let downloadRetryPolicy = RetryPolicy(retryLimit: 6)
}
