//
//  AFSession+Tools.swift
//  EMHenTai
//
//  Created by yuman on 2024/7/29.
//

import Alamofire
import Foundation

/// A real Safari UA: the default `EMHenTai/... Alamofire/...` identifier is treated as a bot
/// by Cloudflare (403 on exhentai.org), and the stock WKWebView UA lacks the
/// `Version/... Safari/...` tokens.
let browserUserAgent: String = {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "Mozilla/5.0 (iPhone; CPU iPhone OS \(v.majorVersion)_\(v.minorVersion)_\(v.patchVersion) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
}()

/// Bump on every release: lets a user screenshot be attributed to an exact build.
let appVersionTag = "v7"

let emSession: Session = {
    let configuration = URLSessionConfiguration.af.default
    configuration.timeoutIntervalForRequest = 30
    configuration.httpAdditionalHeaders = ["User-Agent": browserUserAgent]
    return Session(configuration: configuration)
}()
