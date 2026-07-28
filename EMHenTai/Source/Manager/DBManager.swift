//
//  DBManager.swift
//  EMHenTai
//
//  Created by yuman on 2022/1/20.
//

import Combine
import Foundation
import SwiftData

/// Keeps the book lists in memory on the main actor so the UI can read them synchronously,
/// and mirrors every mutation into `BookStore`, which runs off the main actor.
@MainActor
final class DBManager {
    enum DBType: String, CaseIterable {
        case history
        case download
    }
    
    static let shared = DBManager()
    
    let dbChangedSubject = PassthroughSubject<DBType, Never>()
    
    private var booksMap = DBType.allCases.reduce(into: [DBType: [Book]]()) { $0[$1] = [] }
    private let store = BookStore()
    /// Store work is chained onto this task so it reaches SwiftData in call order.
    private var storeTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private init() {}
    
    func setupDB() {
        loadTask = enqueueStoreWork { store in
            let loaded = await store.loadAll()
            self.mergeLoadedBooks(loaded)
        }
    }
    
    /// Reads are synchronous and return empty until the launch-time load lands, so anything that
    /// makes a destructive decision from the book lists has to await this first.
    func waitUntilLoaded() async {
        await loadTask?.value
    }
    
    func books(of type: DBType) -> [Book] {
        booksMap[type] ?? []
    }
    
    func contains(gid: Int, of type: DBType) -> Bool {
        booksMap[type]?.contains(where: { $0.gid == gid }) ?? false
    }
    
    func insert(book: Book, of type: DBType) {
        guard !contains(gid: book.gid, of: type) else { return }
        
        booksMap[type, default: []].insert(book, at: 0)
        dbChangedSubject.send(type)
        
        enqueueStoreWork { await $0.insert(book: book, of: type) }
    }
    
    func remove(book: Book, of type: DBType) {
        booksMap[type]?.removeAll { $0.gid == book.gid }
        dbChangedSubject.send(type)
        
        let gid = book.gid
        enqueueStoreWork { await $0.remove(gid: gid, of: type) }
    }
    
    func removeAll(type: DBType) {
        booksMap[type]?.removeAll()
        dbChangedSubject.send(type)
        
        enqueueStoreWork { await $0.removeAll(of: type) }
    }
    
    /// Books inserted before the initial load finished are kept, so nothing is dropped at launch.
    private func mergeLoadedBooks(_ loaded: [DBType: [Book]]) {
        for (type, books) in loaded {
            let pending = booksMap[type] ?? []
            let pendingGids = Set(pending.map(\.gid))
            booksMap[type] = pending + books.filter { !pendingGids.contains($0.gid) }
            dbChangedSubject.send(type)
        }
    }
    
    @discardableResult
    private func enqueueStoreWork(_ work: @escaping @MainActor @Sendable (BookStore) async -> Void) -> Task<Void, Never> {
        let previous = storeTask
        let task = Task { [store] in
            await previous?.value
            await work(store)
        }
        storeTask = task
        return task
    }
}

/// Owns the SwiftData stack. Being an actor keeps every context access off the main actor,
/// so opening the store and running queries never block the UI.
private actor BookStore {
    private lazy var context: ModelContext? = {
        guard let container = try? ModelContainer(for: BookRecord.self) else { return nil }
        return ModelContext(container)
    }()
    
    func loadAll() -> [DBManager.DBType: [Book]] {
        guard let context else { return [:] }
        return DBManager.DBType.allCases.reduce(into: [DBManager.DBType: [Book]]()) { map, type in
            let typeValue = type.rawValue
            let descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { $0.typeValue == typeValue },
                sortBy: [SortDescriptor(\.createDate, order: .reverse)]
            )
            map[type] = ((try? context.fetch(descriptor)) ?? []).map(\.book)
        }
    }
    
    func insert(book: Book, of type: DBManager.DBType) {
        guard let context else { return }
        context.insert(BookRecord(book: book, typeValue: type.rawValue))
        try? context.save()
    }
    
    func remove(gid: Int, of type: DBManager.DBType) {
        guard let context else { return }
        let typeValue = type.rawValue
        try? context.delete(model: BookRecord.self, where: #Predicate { $0.typeValue == typeValue && $0.gid == gid })
        try? context.save()
    }
    
    func removeAll(of type: DBManager.DBType) {
        guard let context else { return }
        let typeValue = type.rawValue
        try? context.delete(model: BookRecord.self, where: #Predicate { $0.typeValue == typeValue })
        try? context.save()
    }
}
