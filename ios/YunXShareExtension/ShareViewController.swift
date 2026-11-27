//
//  ShareViewController.swift
//  YunXShareExtension
//
//  iOS 系统分享扩展入口：在 Safari / 微信 / 小红书 / B站等 App 中点击「分享 → 用云析解析」，
//  提取链接或完整分享文案后通过 yunx://resolve?text=... 唤起主 App 自动分流解析。
//

import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let closeButton = UIButton(type: .system)
    private var didBeginExtraction = false

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didBeginExtraction else { return }
        didBeginExtraction = true
        Task { await extractAndHandoff() }
    }

    private func setupUI() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.32)

        let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = 20
        card.clipsToBounds = true
        view.addSubview(card)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "正在用云析打开解析…"
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 3

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("关闭", for: .normal)
        closeButton.isHidden = true
        closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [spinner, statusLabel, closeButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        card.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),

            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -22),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -20)
        ])
    }

    private func extractAndHandoff() async {
        let extracted = await extractSharedPayload()
        guard let payload = extracted?.trimmingCharacters(in: .whitespacesAndNewlines), !payload.isEmpty else {
            showError("未在分享内容中检测到可用链接或文本")
            return
        }

        var components = URLComponents()
        components.scheme = "yunx"
        components.host = "resolve"
        components.queryItems = [URLQueryItem(name: "text", value: payload)]
        guard let targetURL = components.url else {
            showError("构造云析唤起链接失败")
            return
        }

        let opened = openHostApp(url: targetURL)
        if opened {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            showError("无法自动跳转至云析，请手动打开云析 App")
        }
    }

    private func extractSharedPayload() async -> String? {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return nil }
        var collectedTexts: [String] = []
        var collectedURLs: [String] = []

        for item in items {
            if let contentText = item.attributedContentText?.string.trimmingCharacters(in: .whitespacesAndNewlines),
               !contentText.isEmpty {
                collectedTexts.append(contentText)
            }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if let url = await loadURL(from: provider) {
                        collectedURLs.append(url.absoluteString)
                    }
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    if let text = await loadText(from: provider), !text.isEmpty {
                        collectedTexts.append(text)
                    }
                }
            }
        }

        // 优先合并文本与 URL（保留分享文案中的提取码），同时避免重复
        var parts: [String] = []
        for t in collectedTexts where !parts.contains(t) {
            parts.append(t)
        }
        let joinedSoFar = parts.joined(separator: " ")
        for u in collectedURLs where !joinedSoFar.contains(u) {
            parts.append(u)
        }
        let result = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let str = item as? String, let url = URL(string: str) {
                    continuation.resume(returning: url)
                } else if let data = item as? Data, let str = String(data: data, encoding: .utf8), let url = URL(string: str) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadText(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                if let str = item as? String {
                    continuation.resume(returning: str.trimmingCharacters(in: .whitespacesAndNewlines))
                } else if let data = item as? Data, let str = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: str.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func openHostApp(url: URL) -> Bool {
        let modernSelector = NSSelectorFromString("openURL:options:completionHandler:")
        let legacySelector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: modernSelector),
               let imp = current.method(for: modernSelector) {
                typealias OpenFunc = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, Any?) -> Void
                let fn = unsafeBitCast(imp, to: OpenFunc.self)
                fn(current, modernSelector, url as NSURL, [:], nil)
                return true
            }
            if current.responds(to: legacySelector) {
                _ = current.perform(legacySelector, with: url)
                return true
            }
            responder = current.next
        }
        return false
    }

    private func showError(_ message: String) {
        spinner.stopAnimating()
        spinner.isHidden = true
        statusLabel.text = message
        closeButton.isHidden = false
    }

    @objc private func handleClose() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
