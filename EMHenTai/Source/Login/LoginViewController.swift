//
//  LoginViewController.swift
//  EMHenTai
//
//  Created by yuman on 2022/3/5.
//

import WebKit

final class LoginViewController: WebViewController {
    /// `home.php` renders the official login form on e-hentai.org itself (no Cloudflare
    /// interstitial), and shows the account page when the session is already signed in.
    private static let loginEntryURL = URL(string: "https://e-hentai.org/home.php")!
    /// Visiting ExHentai with valid login cookies is the only way to obtain the `igneous` cookie.
    private static let exhentaiURL = URL(string: "https://exhentai.org/")!

    private let activityIndicator = UIActivityIndicatorView(style: .large)
    private var didDetectLogin = false
    private var didVisitExhentai = false

    init() {
        super.init(url: LoginViewController.loginEntryURL)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.customUserAgent = Self.safariUserAgent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.hidesWhenStopped = true
        view.addSubview(activityIndicator)
        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(doneAction))
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if webView.isLoading { activityIndicator.startAnimating() }
    }

    @objc
    private func doneAction() {
        navigationController?.popViewController(animated: true)
    }

    /// The stock WKWebView UA lacks the `Version/... Safari/...` tokens, which makes
    /// Cloudflare serve a challenge the web view then fails to render (white screen).
    private static func safariUserAgent() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(v.majorVersion)_\(v.minorVersion)_\(v.patchVersion) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    }

    private static func isValidLoginValue(_ value: String) -> Bool {
        !value.isEmpty && value.lowercased() != "mystery" && value.lowercased() != "null"
    }

    private static func hasSignedIn(_ cookies: [HTTPCookie]) -> Bool {
        var memberID = false, passHash = false
        for cookie in cookies where cookie.domain.hasSuffix("e-hentai.org") {
            if cookie.name == "ipb_member_id", isValidLoginValue(cookie.value) { memberID = true }
            if cookie.name == "ipb_pass_hash", isValidLoginValue(cookie.value) { passHash = true }
        }
        return memberID && passHash
    }
}

extension LoginViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        activityIndicator.startAnimating()
    }

    private static let loginCookieNames: Set<String> = ["ipb_member_id", "ipb_pass_hash", "igneous"]

    /// WKWebView hands over session cookies (no expiry) for the login state; HTTPCookieStorage
    /// drops those on app termination, so re-issue them with a far-future expiry to persist.
    private static func persist(_ cookie: HTTPCookie) -> HTTPCookie? {
        guard cookie.expiresDate == nil, loginCookieNames.contains(cookie.name),
              let properties = cookie.properties else { return nil }
        var mutable = properties
        mutable[.expires] = Date(timeIntervalSinceNow: 31_536_000)
        return HTTPCookie(properties: mutable)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        activityIndicator.stopAnimating()
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            cookies.forEach {
                HTTPCookieStorage.shared.setCookie($0)
                if let persistent = Self.persist($0) { HTTPCookieStorage.shared.setCookie(persistent) }
            }

            if !self.didDetectLogin {
                guard Self.hasSignedIn(cookies) else { return }
                self.didDetectLogin = true
                guard !self.didVisitExhentai else { return }
                self.didVisitExhentai = true
                // Fetch the igneous cookie required by ExHentai, then leave automatically.
                self.webView.load(URLRequest(url: Self.exhentaiURL))
                return
            }
            // The exhentai visit redirects through forums/remoteapi, which fires didFinish
            // for intermediate pages too; only leave once the final exhentai page is shown.
            if self.didVisitExhentai, webView.url?.host?.hasSuffix("exhentai.org") == true {
                self.navigationController?.popViewController(animated: true)
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        activityIndicator.stopAnimating()
        handleLoadFailure()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        activityIndicator.stopAnimating()
        handleLoadFailure()
    }

    /// Failing to fetch the igneous cookie (exhentai.org is unreachable on some networks)
    /// is not a login failure: the session is already valid on e-hentai, so just leave.
    private func handleLoadFailure() {
        if didDetectLogin {
            navigationController?.popViewController(animated: true)
            return
        }
        presentRetryAlert()
    }

    private func presentRetryAlert() {
        guard presentedViewController == nil else { return }
        let vc = UIAlertController(title: "alert.warning".localized, message: "setting.login_load_failed".localized, preferredStyle: .alert)
        vc.addAction(UIAlertAction(title: "setting.retry".localized, style: .default, handler: { [weak self] _ in
            guard let self else { return }
            let url = self.didDetectLogin ? Self.exhentaiURL : Self.loginEntryURL
            self.webView.load(URLRequest(url: url))
        }))
        vc.addAction(UIAlertAction(title: "alert.cancel".localized, style: .cancel))
        present(vc, animated: true)
    }
}
