//
//  TranslateManager.swift
//  EMHenTai
//
//  Created by yuman on 2022/1/24.
//

import Foundation

// https://github.com/EhTagTranslation/Database/releases    db.text.json
final class TranslateManager: Sendable {
    static let shared = TranslateManager()
    
    private let dictEn: [String: String]
    private let dictCn: [String: String]
    
    private init () {
        (dictEn, dictCn) = Self.loadDictionaries()
    }
    
    private static func loadDictionaries() -> (en: [String: String], cn: [String: String]) {
        guard let url = Bundle.main.urls(forResourcesWithExtension: ".json", subdirectory: nil)?.first,
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let content = obj["data"] as? [[String: Any]] else { return ([:], [:]) }
        
        var dictEn = [String: String]()
        var dictCn = [String: String]()
        
        for dic in content {
            guard let namespace = dic["namespace"] as? String, namespace != "rows",
                  let data = dic["data"] as? [String: [String: String]] else { continue }
            
            for (key, value) in data {
                guard !key.isEmpty, let name = value["name"], !name.isEmpty, key.lowercased() != name.lowercased() else { continue }
                dictEn[key] = name
                dictCn[name] = key
            }
        }
        
        return (dictEn, dictCn)
    }
    
    func translateEn(_ en: String) -> String {
        dictEn[en].flatMap { "(\($0))" } ?? ""
    }
    
    func translateCn(_ cn: String) -> String {
        dictCn[cn] ?? cn
    }
}
