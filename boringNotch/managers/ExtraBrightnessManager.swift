//
//  ExtraBrightnessManager.swift
//  boringNotch
//
//  Unlocks MacBook Pro / XDR peak brightness beyond the normal SDR ceiling.
//  Backends: BrightIntosh, Fullbright-style, XDR Boost (multiply).
//

import AppKit
import Combine
import CoreGraphics
import Defaults
import Foundation
import IOKit

extension NSScreen {
    var displayId: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? CGDirectDisplayID
    }
}

/// MacBook Pro Liquid Retina XDR models.
let xdrSupportedDevices: Set<String> = [
    "MacBookPro18,1", "MacBookPro18,2", "MacBookPro18,3", "MacBookPro18,4",
    "Mac14,5", "Mac14,6", "Mac14,9", "Mac14,10",
    "Mac15,3", "Mac15,6", "Mac15,7", "Mac15,8", "Mac15,9", "Mac15,10", "Mac15,11",
    "Mac16,1", "Mac16,5", "Mac16,6", "Mac16,7", "Mac16,8",
    "Mac17,2", "Mac17,6", "Mac17,7", "Mac17,8", "Mac17,9",
]

let sdr600NitsDevices: Set<String> = [
    "Mac15,3", "Mac15,6", "Mac15,7", "Mac15,8", "Mac15,9", "Mac15,10", "Mac15,11",
    "Mac16,1", "Mac16,5", "Mac16,6", "Mac16,7", "Mac16,8",
    "Mac17,2", "Mac17,6", "Mac17,7", "Mac17,8", "Mac17,9",
]

private let externalXDRDisplayNames: Set<String> = [
    "Pro Display XDR",
    "Studio Display XDR",
]

@MainActor
final class ExtraBrightnessManager: ObservableObject {
    static let shared = ExtraBrightnessManager()

    @Published private(set) var isActive: Bool = false
    @Published private(set) var isSupported: Bool = false
    @Published private(set) var currentFactor: Float = 1.0
    @Published private(set) var intensity: Float = 0
    @Published private(set) var activeBackend: ExtraBrightnessBackend = Defaults[.extraBrightnessBackend]

    private var technique: ExtraBrightnessTechnique?
    private var cancellables = Set<AnyCancellable>()
    private var screenDebounceTask: Task<Void, Never>?
    private var factorPollTask: Task<Void, Never>?

    private init() {
        refreshSupport()
        intensity = Float(Defaults[.extraBrightnessIntensity])
        activeBackend = Defaults[.extraBrightnessBackend]
        technique = makeTechnique(activeBackend)

        Defaults.publisher(.extraBrightnessEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self else { return }
                if !change.newValue {
                    self.setIntensity(0)
                } else if self.intensity > 0 {
                    self.applyIntensity()
                }
            }
            .store(in: &cancellables)

        Defaults.publisher(.extraBrightnessBackend)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                self?.switchBackend(to: change.newValue)
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screensDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        if Defaults[.extraBrightnessEnabled], intensity > 0.001 {
            applyIntensity()
        }

        factorPollTask = Task { @MainActor in
            while !Task.isCancelled {
                if let t = self.technique {
                    self.isActive = t.isActive
                    self.currentFactor = t.currentFactor
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func refreshSupport() {
        isSupported = ExtraBrightnessSupport.isSetupSupported()
        if !isSupported, intensity > 0 {
            setIntensity(0)
        }
    }

    func toggle() {
        guard isSupported, Defaults[.extraBrightnessEnabled] else { return }
        setIntensity(intensity > 0.001 ? 0 : 1)
    }

    func setEnabled(_ enabled: Bool) {
        if !enabled { setIntensity(0) }
    }

    func setIntensity(_ value: Float) {
        refreshSupport()
        let clamped = max(0, min(1, value))
        guard isSupported, Defaults[.extraBrightnessEnabled] || clamped == 0 else {
            intensity = 0
            Defaults[.extraBrightnessIntensity] = 0
            technique?.disable()
            isActive = false
            currentFactor = 1
            return
        }

        intensity = clamped
        Defaults[.extraBrightnessIntensity] = Double(clamped)
        applyIntensity()
    }

    private func applyIntensity() {
        if technique == nil {
            technique = makeTechnique(activeBackend)
        }
        technique?.setIntensity(intensity)
        isActive = technique?.isActive ?? false
        currentFactor = technique?.currentFactor ?? 1
    }

    private func switchBackend(to backend: ExtraBrightnessBackend) {
        let wasOn = intensity > 0.001
        technique?.disable()
        technique = nil
        activeBackend = backend
        technique = makeTechnique(backend)
        if wasOn, Defaults[.extraBrightnessEnabled] {
            applyIntensity()
        }
    }

    private func makeTechnique(_ backend: ExtraBrightnessBackend) -> ExtraBrightnessTechnique {
        switch backend {
        case .brightIntosh: return BrightIntoshTechnique()
        case .fullbright: return FullbrightTechnique()
        case .xdrBoost: return XDRBoostTechnique()
        }
    }

    @objc private func screenParametersChanged() {
        screenDebounceTask?.cancel()
        screenDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            self.refreshSupport()
            self.technique?.handleScreenChange()
        }
    }

    @objc private func screensDidSleep() {
        technique?.handleSleep()
    }

    @objc private func didWake() {
        technique?.handleWake()
    }
}

// MARK: - Support helpers

enum ExtraBrightnessSupport {
    static func modelIdentifier() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let modelData = IORegistryEntryCreateCFProperty(
            service, "model" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? Data else {
            return nil
        }
        return String(data: modelData, encoding: .utf8)?
            .trimmingCharacters(in: .controlCharacters)
    }

    static func isDeviceSupported() -> Bool {
        guard let model = modelIdentifier() else { return false }
        return xdrSupportedDevices.contains(model)
    }

    static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let id = screen.displayId else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }

    static func isExternalXDR(_ screen: NSScreen) -> Bool {
        externalXDRDisplayNames.contains(screen.localizedName)
    }

    @MainActor
    static func isScreenSupported(_ screen: NSScreen) -> Bool {
        if isBuiltIn(screen), isDeviceSupported() { return true }
        if isExternalXDR(screen) { return true }
        if screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.05 {
            return true
        }
        return false
    }

    @MainActor
    static func isSetupSupported() -> Bool {
        if isDeviceSupported() { return true }
        return NSScreen.screens.contains(where: isScreenSupported)
    }

    @MainActor
    static func xdrDisplays() -> [NSScreen] {
        NSScreen.screens.filter(isScreenSupported)
    }

    static func brightnessFactor(screen: NSScreen, maxEdr: CGFloat) -> Float {
        let (referenceEdr, referenceBonus): (Float, Float)
        if let id = screen.displayId, CGDisplayIsBuiltin(id) != 0 {
            if let model = modelIdentifier(), sdr600NitsDevices.contains(model) {
                referenceEdr = 2.66
                referenceBonus = 0.50
            } else {
                referenceEdr = 3.2
                referenceBonus = 0.59
            }
        } else {
            referenceEdr = 2.66
            referenceBonus = 0.6
        }
        return 1 + referenceBonus * min(Float(maxEdr) / referenceEdr, 1.0)
    }
}

// MARK: - Gamma table

final class ExtraBrightnessGammaTable {
    static let tableSize: UInt32 = 256
    private static let boostedThreshold: CGGammaValue = 1.1

    private(set) var redTable = [CGGammaValue](repeating: 0, count: Int(tableSize))
    private(set) var greenTable = [CGGammaValue](repeating: 0, count: Int(tableSize))
    private(set) var blueTable = [CGGammaValue](repeating: 0, count: Int(tableSize))

    private init() {}

    static func createFromCurrent(displayId: CGDirectDisplayID) -> ExtraBrightnessGammaTable? {
        let table = ExtraBrightnessGammaTable()
        var sampleCount: UInt32 = 0
        let result = CGGetDisplayTransferByTable(
            displayId,
            tableSize,
            &table.redTable,
            &table.greenTable,
            &table.blueTable,
            &sampleCount
        )
        guard result == .success else { return nil }
        return table
    }

    static func createCleanBaseline(displayId: CGDirectDisplayID) -> ExtraBrightnessGammaTable? {
        guard let current = createFromCurrent(displayId: displayId) else { return nil }
        guard current.appearsBoosted else { return current }

        CGDisplayRestoreColorSyncSettings()
        guard let restored = createFromCurrent(displayId: displayId) else {
            return current.normalizedByMaximum()
        }
        return restored.appearsBoosted ? restored.normalizedByMaximum() : restored
    }

    func setTable(displayId: CGDirectDisplayID, factor: Float = 1.0) {
        var red = redTable
        var green = greenTable
        var blue = blueTable
        for i in 0..<red.count {
            red[i] *= factor
            green[i] *= factor
            blue[i] *= factor
        }
        CGSetDisplayTransferByTable(displayId, Self.tableSize, &red, &green, &blue)
    }

    private var maximumValue: CGGammaValue {
        max(redTable.max() ?? 0, greenTable.max() ?? 0, blueTable.max() ?? 0)
    }

    private var appearsBoosted: Bool {
        maximumValue > Self.boostedThreshold
    }

    private func normalizedByMaximum() -> ExtraBrightnessGammaTable? {
        let maxValue = maximumValue
        guard maxValue > 0 else { return nil }
        let table = ExtraBrightnessGammaTable()
        table.redTable = redTable.map { $0 / maxValue }
        table.greenTable = greenTable.map { $0 / maxValue }
        table.blueTable = blueTable.map { $0 / maxValue }
        return table
    }
}
