//
//  DBManager.swift
//  EMHenTai
//
//  Created by yuman on 2022/1/20.
//

import Combine
import Foundation
import SwiftData

final class DBManager {
    enum DBType: String, CaseIterable {
        case history
        case download
    }
    
    static let shared = DBManager()
    
    let dbChangedSubject = PassthroughSubject<DBType, Never>()
    
    private var booksMap = [DBType: [Book]]()
    private let queue = DispatchQueue(label: "com.DBManager.ConcurrentQueue", attributes: .concurrent)
    private let storeQueue = DispatchQueue(label: "com.DBManager.StoreQueue")
    private var context: ModelContext?
    private init() {}
    
    func setupDB() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            booksMap = storeQueue.sync {
                guard let container = try? ModelContainer(for: BookRecord.self) else { return [DBType: [Book]]() }
                let context = ModelContext(container)
                self.context = context
                return DBType.allCases.reduce(into: [DBType: [Book]]()) { map, type in
                    map[type] = Self.fetchBooks(of: type, in: context)
                }
            }
        }
    }
    
    func books(of type: DBType) -> [Book] {
        queue.sync { booksMap[type] ?? [] }
    }
    
    func contains(gid: Int, of type: DBType) -> Bool {
        queue.sync { p_contains(gid: gid, of: type) }
    }
    
    private func p_contains(gid: Int, of type: DBType) -> Bool {
        booksMap[type]?.contains(where: { $0.gid == gid }) ?? false
    }
    
    func insert(book: Book, of type: DBType) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self, !p_contains(gid: book.gid, of: type) else { return }
            
            booksMap[type]?.insert(book, at: 0)
            dbChangedSubject.send(type)
            
            storeQueue.async { [weak self] in
                guard let self, let context else { return }
                context.insert(BookRecord(book: book, typeValue: type.rawValue))
                try? context.save()
            }
        }
    }
    
    func remove(book: Book, of type: DBType) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            
            booksMap[type]?.removeAll { $0.gid == book.gid }
            dbChangedSubject.send(type)
            
            storeQueue.async { [weak self] in
                guard let self, let context else { return }
                let (typeValue, gid) = (type.rawValue, book.gid)
                try? context.delete(model: BookRecord.self, where: #Predicate { $0.typeValue == typeValue && $0.gid == gid })
                try? context.save()
            }
        }
    }
    
    func removeAll(type: DBType) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            
            booksMap[type]?.removeAll()
            dbChangedSubject.send(type)
            
            storeQueue.async { [weak self] in
                guard let self, let context else { return }
                let typeValue = type.rawValue
                try? context.delete(model: BookRecord.self, where: #Predicate { $0.typeValue == typeValue })
                try? context.save()
            }
        }
    }
    
    private static func fetchBooks(of type: DBType, in context: ModelContext) -> [Book] {
        let typeValue = type.rawValue
        let descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { $0.typeValue == typeValue },
            sortBy: [SortDescriptor(\.createDate, order: .reverse)]
        )
        return ((try? context.fetch(descriptor)) ?? []).map(\.book)
    }
}
