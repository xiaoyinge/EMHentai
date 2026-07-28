//
//  BookRecord.swift
//  EMHenTai
//
//  Created by yuman on 2022/1/20.
//

import Foundation
import SwiftData

@Model
final class BookRecord {
    #Unique<BookRecord>([\.typeValue, \.gid])
    #Index<BookRecord>([\.typeValue, \.gid], [\.typeValue, \.createDate])

    var typeValue: String = ""
    var gid: Int = 0
    var title: String?
    var titleJpn: String?
    var category: String?
    var thumb: String?
    var fileCount: Int = 0
    var tags: [String] = []
    var token: String?
    var rating: String?
    /// SwiftData fetches have no implicit insertion order, so keep an explicit timestamp to restore the newest-first list order.
    var createDate: Date = Date.now

    init(book: Book, typeValue: String) {
        self.typeValue = typeValue
        gid = book.gid
        title = book.title
        titleJpn = book.titleJpn
        category = book.category
        thumb = book.thumb
        fileCount = book.fileCount
        tags = book.tags
        token = book.token
        rating = book.rating
    }

    var book: Book {
        Book(
            gid: gid,
            title: title,
            titleJpn: titleJpn,
            category: category,
            thumb: thumb,
            fileCount: fileCount,
            tags: tags,
            token: token,
            rating: rating
        )
    }
}
