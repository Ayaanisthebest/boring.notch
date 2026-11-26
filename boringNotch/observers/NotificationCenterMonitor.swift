//
//  NotificationCenterMonitor.swift
//  boringNotch
//

import AppKit
import ApplicationServices
import Defaults

/// Watches Notification Center banners, copies their text, dismisses the system banner,
/// and hands the content to the notch.
final class NotificationCenterMonitor {
    static let shared = NotificationCenterMonitor()

    private let bundleID = "com.apple.notificationcenterui"
    private let bannerSubroles: Set<String> = ["AXNotificationCenterBanner", "AXNotificationCenterAlert"]
    private let observedNames: [CFString] = [
        kAXWindowCreatedNotification as CFString,
        kAXCreatedNotification as CFString,
        kAXUIElementDestroyedNotification as CFString,
        "AXLayoutChanged" as CFString,
        "AXChildrenChanged" as CFString
    ]

    private var observer: AXObserver?
    private var observedApp: AXUIElement?
    private var observedPid: pid_t = 0
    private var pollTask: Task<Void, Never>?
    private var isRunning = false
    private var seen: [String: Date] = [:]
    private var retained: [String: AXUIElement] = [:]
    private var parkedOrigins: [String: CGPoint] = [:]
    private var opening: Set<String> = []

    private var lastTrusted: Bool?
    private let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/boringNotch-notifications.log")

    private init() {}

    private func log(_ message: String) {
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: logURL)
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        log("start trusted=\(Self.isTrusted()) enabled=\(Defaults[.notchNotificationsEnabled]) ncPid=\(notificationCenterPid().map(String.init) ?? "none")")
        installObserver()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stop() {
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
        removeObserver()
    }

    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    static func prompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func openNotification(id: String, appName: String, bundleIdentifier: String?) {
        opening.insert(id)
        guard let element = retained[id], isAlive(element) else {
            launchApp(named: appName, bundleIdentifier: resolvedBundleIdentifier(bundleIdentifier, appName: appName))
            return
        }
        let window = ancestor(element, role: kAXWindowRole as String) ?? element
        move(window, to: parkedOrigins[id] ?? .zero)
        let destination = resolvedBundleIdentifier(bundleIdentifier, appName: appName)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            let opened = self.isAlive(element)
                && self.openAction(of: element).map { AXUIElementPerformAction(element, $0 as CFString) == .success } == true
            self.retained[id] = nil
            if destination == "com.apple.MobileSMS" || !opened {
                self.launchApp(named: appName, bundleIdentifier: destination ?? bundleIdentifier)
            }
        }
    }

    // MARK: - Observer

    private func installObserver() {
        guard Self.isTrusted(), let pid = notificationCenterPid() else { return }
        if observer != nil, observedPid == pid { return }
        removeObserver()

        var created: AXObserver?
        let error = AXObserverCreate(pid, { _, element, _, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<NotificationCenterMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handle(event: element)
        }, &created)
        log("observer create pid=\(pid) result=\(error.rawValue)")
        guard error == .success, let created else { return }

        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in observedNames {
            let result = AXObserverAddNotification(created, element, name, refcon)
            log("observe \(name) result=\(result.rawValue)")
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)

        observer = created
        observedApp = element
        observedPid = pid
    }

    private func removeObserver() {
        if let observer, let observedApp {
            for name in observedNames {
                AXObserverRemoveNotification(observer, observedApp, name)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        observedApp = nil
        observedPid = 0
    }

    private func notificationCenterPid() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
    }

    // MARK: - Discovery

    private func handle(event element: AXUIElement) {
        guard isRunning, Defaults[.notchNotificationsEnabled] else { return }
        var banners = banners(in: element, depth: 0)
        if banners.isEmpty, let owner = enclosingBanner(of: element) {
            banners = [owner]
        }
        if banners.isEmpty {
            poll()
        } else {
            process(banners)
        }
    }

    private func poll() {
        let trusted = Self.isTrusted()
        if trusted != lastTrusted {
            lastTrusted = trusted
            log("trusted=\(trusted)")
        }
        guard isRunning, Defaults[.notchNotificationsEnabled], trusted else { return }
        installObserver()
        guard let app = observedApp else { return }
        pruneSeen()
        var found: [AXUIElement] = []
        let windows = values(app, kAXWindowsAttribute)
        let children = values(app, kAXChildrenAttribute)
        for root in windows + children {
            found.append(contentsOf: banners(in: root, depth: 0))
        }
        let shape = "windows=\(windows.count) children=\(children.count) banners=\(found.count)"
        if shape != lastShape {
            lastShape = shape
            log(shape + " tree=" + describe(windows.first ?? children.first, depth: 0))
        }
        process(found)
    }

    private var lastShape = ""

    private func describe(_ element: AXUIElement?, depth: Int) -> String {
        guard let element, depth < 6 else { return "" }
        let role = string(element, kAXRoleAttribute) ?? "?"
        let subrole = string(element, kAXSubroleAttribute) ?? ""
        let kids = values(element, kAXChildrenAttribute)
        let inner = kids.prefix(4).map { describe($0, depth: depth + 1) }.joined(separator: ",")
        return "\(role)/\(subrole)[\(inner)]"
    }

    private func banners(in element: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth < 8 else { return [] }
        if let subrole = string(element, kAXSubroleAttribute), bannerSubroles.contains(subrole) {
            return [element]
        }
        return values(element, kAXChildrenAttribute).flatMap { banners(in: $0, depth: depth + 1) }
    }

    private func enclosingBanner(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<6 {
            guard let node = current else { return nil }
            if let subrole = string(node, kAXSubroleAttribute), bannerSubroles.contains(subrole) {
                return node
            }
            current = parent(of: node)
        }
        return nil
    }

    private func process(_ banners: [AXUIElement]) {
        guard !banners.isEmpty else { return }
        let panelOpen = isPanelOpen()
        var live: [NotchNotificationItem] = []
        var listed: [NotchNotificationItem] = []

        for banner in banners {
            let key = signature(of: banner)
            guard !key.isEmpty, seen[key] == nil else { continue }
            guard let item = makeItem(from: banner, id: key) else {
                log("banner without text key=\(key)")
                continue
            }
            log("banner app=\(item.appName) bundle=\(item.bundleIdentifier ?? "-") title=\(item.title) panel=\(panelOpen)")
            seen[key] = Date()
            retained[key] = banner
            if panelOpen {
                listed.append(item)
            } else {
                hideBanner(banner)
                live.append(item)
            }
        }

        guard !live.isEmpty || !listed.isEmpty else { return }
        log("notch live=\(live.count) listed=\(listed.count)")
        Task { @MainActor in
            let presenter = NotchNotificationPresenter.shared
            presenter.record(listed)
            for item in live {
                presenter.present(item)
            }
        }
    }

    private func isPanelOpen() -> Bool {
        guard let app = observedApp else { return false }
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success
            && value != nil
    }

    private func isInsidePanel(_ banner: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(banner, kAXWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        let window = value as! AXUIElement
        return (size(of: window)?.height ?? 0) > 420
    }

    // MARK: - Content

    private func makeItem(from banner: AXUIElement, id: String) -> NotchNotificationItem? {
        var title = ""
        var subtitle = ""
        var body = ""
        var loose: [String] = []
        collectTexts(in: banner, depth: 0) { identifier, value in
            switch identifier {
            case "title": title = value
            case "subtitle": subtitle = value
            case "body": body = value
            default: loose.append(value)
            }
        }
        if title.isEmpty, !loose.isEmpty { title = loose.removeFirst() }
        if body.isEmpty, !loose.isEmpty { body = loose.joined(separator: "\n") }
        guard !title.isEmpty || !body.isEmpty else { return nil }
        if !subtitle.isEmpty { body = body.isEmpty ? subtitle : subtitle + "\n" + body }

        let description = attributedDescription(of: banner)
        var appName = ""
        if !title.isEmpty, let range = description.range(of: ", " + title) {
            appName = String(description[..<range.lowerBound])
        } else if let first = description.components(separatedBy: ", ").first, first != title {
            appName = first
        }
        appName = appName.trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedBundle = bundleIdentifier(of: banner) ?? knownBundleIdentifier(forAppNamed: appName)
        let appURL = resolvedBundle.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            ?? applicationURL(named: appName)
        if appName.isEmpty {
            appName = appURL.map { $0.deletingPathExtension().lastPathComponent } ?? "Notification"
        }
        let bundleIdentifier = resolvedBundle
            ?? appURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
            ?? runningApp(named: appName)?.bundleIdentifier
        let icon = appURL.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? runningApp(named: appName)?.icon

        return NotchNotificationItem(
            id: id,
            appName: appName,
            title: title.isEmpty ? appName : title,
            body: body,
            icon: icon,
            bundleIdentifier: bundleIdentifier
        )
    }

    private func collectTexts(in element: AXUIElement, depth: Int, _ found: (String, String) -> Void) {
        guard depth < 6 else { return }
        if string(element, kAXRoleAttribute) == kAXStaticTextRole as String,
           let value = (string(element, kAXValueAttribute) ?? string(element, kAXTitleAttribute))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            found(string(element, kAXIdentifierAttribute) ?? "", value)
        }
        for child in values(element, kAXChildrenAttribute) {
            collectTexts(in: child, depth: depth + 1, found)
        }
    }

    private func attributedDescription(of element: AXUIElement) -> String {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXAttributedDescription" as CFString, &value) == .success,
           let attributed = value as? NSAttributedString {
            return attributed.string
        }
        return string(element, kAXDescriptionAttribute) ?? ""
    }

    private func applicationURL(named name: String) -> URL? {
        guard !name.isEmpty else { return nil }
        if let running = runningApp(named: name)?.bundleURL {
            return running
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/Applications/Utilities",
            "\(home)/Applications",
            "/System/Library/CoreServices"
        ]
        for folder in folders {
            let root = URL(fileURLWithPath: folder)
            if let match = app(named: name, in: root) {
                return match
            }
        }
        return nil
    }

    private func app(named name: String, in folder: URL) -> URL? {
        let direct = folder.appendingPathComponent("\(name).app")
        if FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return children.first { child in
            child.pathExtension == "app"
                && child.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func bundleIdentifier(of banner: AXUIElement) -> String? {
        guard let stacking = string(banner, "AXStackingIdentifier"), !stacking.isEmpty else { return nil }
        if stacking.contains("MobileSMS") {
            return "com.apple.MobileSMS"
        }
        let tokens = stacking.components(separatedBy: CharacterSet(charactersIn: ",;= "))
        for token in tokens where token.contains(".") && !token.lowercased().contains("quicklook") {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: token) != nil {
                return token
            }
        }
        return nil
    }

    private func knownBundleIdentifier(forAppNamed name: String) -> String? {
        switch name.lowercased() {
        case "messages", "imessage":
            return "com.apple.MobileSMS"
        case "mail":
            return "com.apple.mail"
        case "calendar":
            return "com.apple.iCal"
        case "reminders":
            return "com.apple.reminders"
        case "notes":
            return "com.apple.Notes"
        default:
            return nil
        }
    }

    private func resolvedBundleIdentifier(_ bundleIdentifier: String?, appName: String) -> String? {
        if bundleIdentifier?.contains("MobileSMS") == true || knownBundleIdentifier(forAppNamed: appName) == "com.apple.MobileSMS" {
            return "com.apple.MobileSMS"
        }
        if let bundleIdentifier, bundleIdentifier.lowercased().contains("quicklook") {
            return knownBundleIdentifier(forAppNamed: appName)
        }
        return bundleIdentifier ?? knownBundleIdentifier(forAppNamed: appName)
    }

    private func signature(of banner: AXUIElement) -> String {
        let texts = staticTexts(in: banner, depth: 0).joined(separator: "|")
        let identifier = string(banner, kAXIdentifierAttribute) ?? ""
        let stacking = string(banner, "AXStackingIdentifier") ?? ""
        return [identifier, stacking, texts].filter { !$0.isEmpty }.joined(separator: "#")
    }

    private func staticTexts(in element: AXUIElement, depth: Int) -> [String] {
        guard depth < 6 else { return [] }
        var texts: [String] = []
        if string(element, kAXRoleAttribute) == kAXStaticTextRole as String,
           let value = string(element, kAXValueAttribute) ?? string(element, kAXTitleAttribute) {
            texts.append(value)
        }
        for child in values(element, kAXChildrenAttribute) {
            texts.append(contentsOf: staticTexts(in: child, depth: depth + 1))
        }
        return texts
    }

    // MARK: - Actions

    /// Moves the banner's overlay window off screen instead of closing it, so macOS still
    /// files the notification in Notification Center when the banner times out.
    private func hideBanner(_ banner: AXUIElement, attempt: Int = 0) {
        let id = signature(of: banner)
        guard !opening.contains(id) else { return }
        let window = ancestor(banner, role: kAXWindowRole as String) ?? banner
        if attempt == 0, parkedOrigins[id] == nil, let origin = position(of: window), origin.x > -1000 {
            parkedOrigins[id] = origin
        }
        move(window, to: CGPoint(x: -8000, y: -8000))
        guard attempt < 6 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.isRunning, self.isAlive(window), !self.opening.contains(id) else { return }
            self.hideBanner(banner, attempt: attempt + 1)
        }
    }

    private func move(_ element: AXUIElement, to point: CGPoint) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    private func position(of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    /// AXPress is the banner click, which opens the conversation. The separate "Show" action
    /// opens a Quick Look preview instead.
    private func openAction(of element: AXUIElement) -> String? {
        let names = actionNames(element)
        if names.contains(kAXPressAction as String) {
            return kAXPressAction as String
        }
        return names.first {
            let title = actionTitle($0)
            return !isCloseName(title) && title != "show" && title != "show details"
        }
    }

    private func actionTitle(_ action: String) -> String {
        (action.components(separatedBy: "\n").first ?? action)
            .replacingOccurrences(of: "Name:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func ancestor(_ element: AXUIElement, role: String) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let node = current else { return nil }
            if string(node, kAXRoleAttribute) == role { return node }
            current = parent(of: node)
        }
        return nil
    }

    private func actionSummary(_ element: AXUIElement) -> String {
        actionNames(element).map { "\($0)=\(actionDescription(element, $0) ?? "")" }.joined(separator: ", ")
    }

    private func pressClose(_ element: AXUIElement, depth: Int) -> Bool {
        guard depth < 10 else { return false }
        for action in actionNames(element) where isCloseName(action) || isCloseName(actionDescription(element, action)) {
            if AXUIElementPerformAction(element, action as CFString) == .success {
                return true
            }
        }
        if string(element, kAXRoleAttribute) == kAXButtonRole as String,
           isCloseName(string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute)),
           AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            return true
        }
        return values(element, kAXChildrenAttribute).contains { pressClose($0, depth: depth + 1) }
    }

    private func performDefaultAction(_ element: AXUIElement, depth: Int) -> Bool {
        guard depth < 5 else { return false }
        let name = string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute)
        if !isCloseName(name), actionNames(element).contains(kAXPressAction as String),
           AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            return true
        }
        if string(element, kAXRoleAttribute) == kAXButtonRole as String { return false }
        return values(element, kAXChildrenAttribute).contains { performDefaultAction($0, depth: depth + 1) }
    }

    private func launchApp(named name: String, bundleIdentifier: String?) {
        let url = bundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            ?? applicationURL(named: name)
        guard let url else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private func isCloseName(_ name: String?) -> Bool {
        guard let name = name?.lowercased() else { return false }
        return name.contains("close") || name.contains("clear") || name.contains("dismiss")
    }

    // MARK: - AX helpers

    private func runningApp(named name: String) -> NSRunningApplication? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    private func pruneSeen() {
        let cutoff = Date().addingTimeInterval(-600)
        seen = seen.filter { $0.value > cutoff }
        if retained.count > 40 {
            retained = retained.filter { seen[$0.key] != nil }
        }
    }

    private func isAlive(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func size(of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    private func values(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let names else { return [] }
        return names as? [String] ?? []
    }

    private func actionDescription(_ element: AXUIElement, _ action: String) -> String? {
        var description: CFString?
        guard AXUIElementCopyActionDescription(element, action as CFString, &description) == .success else { return nil }
        return description as String?
    }
}