//
//  ExtraBrightnessTechniques.swift
//  boringNotch
//
//  Three XDR unlock backends:
//  - BrightIntosh: 1×1 HDR sample + capped gamma  (GPL-3.0 technique)
//  - Fullbright: SkyLight unlock + strong EDR trigger + peak gamma
//    adapted from https://github.com/137137137/Fullbright
//  - XDR Boost: fullscreen multiply Metal overlay
//    adapted from https://github.com/levelsio/xdr-boost (MIT)
//

import AppKit
import CoreGraphics
import Defaults
import MetalKit
import OSLog

enum ExtraBrightnessBackend: String, CaseIterable, Identifiable, Defaults.Serializable {
    case brightIntosh
    case fullbright
    case xdrBoost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brightIntosh: return "BrightIntosh"
        case .fullbright: return "Fullbright"
        case .xdrBoost: return "XDR Boost"
        }
    }

    var subtitle: String {
        switch self {
        case .brightIntosh:
            return "Balanced HDR pixel + gamma (~1.5×). Closest to BrightIntosh."
        case .fullbright:
            return "SkyLight unlock + strong EDR trigger + peak gamma. Aims for ~1600 nits."
        case .xdrBoost:
            return "Fullscreen multiply overlay (no gamma). Can go up to ~4×."
        }
    }
}

@MainActor
protocol ExtraBrightnessTechnique: AnyObject {
    var isActive: Bool { get }
    var currentFactor: Float { get }
    func setIntensity(_ intensity: Float)
    func disable()
    func handleScreenChange()
    func handleSleep()
    func handleWake()
}

// MARK: - Shared Metal helpers

@MainActor
enum ExtraBrightnessMetal {
    static func makeTriggerView(clear: Double, size: CGSize = CGSize(width: 2, height: 2)) -> ExtraBrightnessMetalView? {
        guard MTLCreateSystemDefaultDevice() != nil else { return nil }
        return ExtraBrightnessMetalView(frame: NSRect(origin: .zero, size: size), clearColorValue: clear)
    }
}

// MARK: - BrightIntosh technique (existing)

@MainActor
final class BrightIntoshTechnique: ExtraBrightnessTechnique {
    private(set) var isActive = false
    private(set) var currentFactor: Float = 1.0

    private var overlays: [CGDirectDisplayID: ExtraBrightnessOverlayController] = [:]
    private var baselines: [CGDirectDisplayID: ExtraBrightnessGammaTable] = [:]
    private var applied: [CGDirectDisplayID: Float] = [:]
    private var pollTask: Task<Void, Never>?
    private var intensity: Float = 0

    private let hdrReady: CGFloat = 1.05
    private let pending: Float = 1.12

    func setIntensity(_ intensity: Float) {
        self.intensity = max(0, min(1, intensity))
        if self.intensity <= 0.001 {
            disable()
            return
        }
        if !isActive {
            enable()
        } else {
            applyGamma()
        }
    }

    private func enable() {
        isActive = true
        CGDisplayRestoreColorSyncSettings()
        updateScreens(ExtraBrightnessSupport.xdrDisplays())
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled, self.isActive {
                self.applyGamma()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func disable() {
        isActive = false
        pollTask?.cancel()
        pollTask = nil
        for (id, table) in baselines { table.setTable(displayId: id, factor: 1.0) }
        overlays.values.forEach { $0.close() }
        overlays.removeAll()
        baselines.removeAll()
        applied.removeAll()
        currentFactor = 1.0
        CGDisplayRestoreColorSyncSettings()
    }

    func handleScreenChange() {
        guard isActive else { return }
        updateScreens(ExtraBrightnessSupport.xdrDisplays())
    }

    func handleSleep() { CGDisplayRestoreColorSyncSettings() }

    func handleWake() {
        guard isActive else { return }
        CGDisplayRestoreColorSyncSettings()
        updateScreens(ExtraBrightnessSupport.xdrDisplays())
    }

    private func updateScreens(_ screens: [NSScreen]) {
        let active = Set(screens.compactMap(\.displayId))
        for id in overlays.keys where !active.contains(id) {
            overlays[id]?.close()
            overlays.removeValue(forKey: id)
            baselines[id]?.setTable(displayId: id, factor: 1)
            baselines.removeValue(forKey: id)
        }
        for screen in screens {
            guard let id = screen.displayId else { continue }
            if baselines[id] == nil {
                CGDisplayRestoreColorSyncSettings()
                baselines[id] = ExtraBrightnessGammaTable.createCleanBaseline(displayId: id)
            }
            if let existing = overlays[id] {
                existing.update(screen: screen)
            } else {
                let c = ExtraBrightnessOverlayController(screen: screen)
                overlays[id] = c
                c.open()
            }
        }
        applyGamma()
    }

    private func applyGamma() {
        guard isActive, intensity > 0.001 else { return }
        var peak: Float = 1
        for (id, table) in baselines {
            guard let screen = NSScreen.screens.first(where: { $0.displayId == id }) else { continue }
            let maxEdr = screen.maximumExtendedDynamicRangeColorComponentValue
            let full: Float = maxEdr > hdrReady
                ? ExtraBrightnessSupport.brightnessFactor(screen: screen, maxEdr: maxEdr)
                : pending
            let factor = 1 + (full - 1) * intensity
            peak = max(peak, factor)
            table.setTable(displayId: id, factor: factor)
            applied[id] = factor
        }
        currentFactor = peak
    }
}

// MARK: - Fullbright-style technique

@MainActor
final class FullbrightTechnique: ExtraBrightnessTechnique {
    private(set) var isActive = false
    private(set) var currentFactor: Float = 1.0

    private var hdrWindows: [CGDirectDisplayID: NSWindow] = [:]
    private var baselines: [CGDirectDisplayID: ExtraBrightnessGammaTable] = [:]
    private var pollTask: Task<Void, Never>?
    private var intensity: Float = 0
    private let logger = Logger(subsystem: "boringNotch", category: "FullbrightXDR")

    func setIntensity(_ intensity: Float) {
        self.intensity = max(0, min(1, intensity))
        if self.intensity <= 0.001 {
            disable()
            return
        }
        if !isActive {
            enable()
        } else {
            applyBoost()
        }
    }

    private func enable() {
        isActive = true
        FullbrightSkyLight.configureForXDR(displayID: CGMainDisplayID())
        CGDisplayRestoreColorSyncSettings()

        for screen in ExtraBrightnessSupport.xdrDisplays() {
            guard let id = screen.displayId else { continue }
            baselines[id] = ExtraBrightnessGammaTable.createCleanBaseline(displayId: id)
            if hdrWindows[id] == nil, let win = FullbrightHDRWindow.make(for: screen) {
                hdrWindows[id] = win
            }
            // Drive backlight to absolute max like Fullbright.
            _ = DisplayServicesLocal.setBrightness(id, 1.0)
            _ = DisplayServicesLocal.setLinearBrightness(id, 1.0)
            _ = DisplayServicesLocal.setAmbientLightCompensation(id, enabled: false)
        }

        applyBoost()
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled, self.isActive {
                self.applyBoost()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        logger.info("Fullbright-style XDR enabled")
    }

    func disable() {
        isActive = false
        pollTask?.cancel()
        pollTask = nil
        for (id, table) in baselines { table.setTable(displayId: id, factor: 1.0) }
        for (id, _) in hdrWindows {
            _ = DisplayServicesLocal.setAmbientLightCompensation(id, enabled: true)
        }
        hdrWindows.values.forEach { $0.close() }
        hdrWindows.removeAll()
        baselines.removeAll()
        currentFactor = 1.0
        CGDisplayRestoreColorSyncSettings()
        logger.info("Fullbright-style XDR disabled")
    }

    func handleScreenChange() {
        guard isActive else { return }
        let screens = ExtraBrightnessSupport.xdrDisplays()
        let active = Set(screens.compactMap(\.displayId))
        for id in hdrWindows.keys where !active.contains(id) {
            hdrWindows[id]?.close()
            hdrWindows.removeValue(forKey: id)
            baselines[id]?.setTable(displayId: id, factor: 1)
            baselines.removeValue(forKey: id)
        }
        for screen in screens {
            guard let id = screen.displayId else { continue }
            if baselines[id] == nil {
                baselines[id] = ExtraBrightnessGammaTable.createCleanBaseline(displayId: id)
            }
            if hdrWindows[id] == nil, let win = FullbrightHDRWindow.make(for: screen) {
                hdrWindows[id] = win
            }
        }
        applyBoost()
    }

    func handleSleep() { CGDisplayRestoreColorSyncSettings() }

    func handleWake() {
        guard isActive else { return }
        CGDisplayRestoreColorSyncSettings()
        handleScreenChange()
    }

    /// Fullbright maps software brightness up to computeMaxEDR(currentHeadroom).
    private func applyBoost() {
        guard isActive, intensity > 0.001 else { return }
        var peak: Float = 1
        for (id, table) in baselines {
            guard let screen = NSScreen.screens.first(where: { $0.displayId == id }) else { continue }
            let current = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
            let maxEDR = FullbrightGamma.computeMaxEDR(edr: max(current, 1.05))
            // 50% → halfway to peak, MAX → full peak
            let factor = 1.0 + (maxEDR - 1.0) * intensity
            peak = max(peak, factor)
            table.setTable(displayId: id, factor: factor)
        }
        currentFactor = peak
    }
}

enum FullbrightGamma {
    /// From Fullbright's GammaTableManager — empirical peak gamma ceiling.
    static func computeMaxEDR(edr: Double) -> Float {
        let rawMax = edr * 0.227317 + 0.899816 + edr * edr * (-0.00590745)
        let capped = max(1.5667381, rawMax)
        return Float(capped + (-0.141))
    }
}

enum FullbrightSkyLight {
    static func configureForXDR(displayID: CGDirectDisplayID) {
        typealias SLSConfigFn = @convention(c) (OpaquePointer, UInt32, UInt32) -> Int32
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
        guard let handle = dlopen(path, RTLD_LAZY),
              let sym = dlsym(handle, "SLSConfigureDisplayEnabled") else { return }
        let configure = unsafeBitCast(sym, to: SLSConfigFn.self)
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { return }
        for mode: UInt32 in [4, 3, 5, 2] {
            _ = configure(cfg, mode, 1)
        }
        _ = CGCompleteDisplayConfiguration(cfg, .permanently)
    }
}

@MainActor
enum FullbrightHDRWindow {
    static func make(for screen: NSScreen) -> NSWindow? {
        let potential = screen.maximumPotentialExtendedDynamicRangeColorComponentValue
        let edrValue = Double(max(1.5, potential))
        let origin = screen.frame.origin
        let window = NSWindow(
            contentRect: NSRect(x: origin.x, y: origin.y, width: 2, height: 2),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none

        if let view = ExtraBrightnessMetal.makeTriggerView(clear: edrValue) {
            window.contentView = view
            view.draw()
        }
        window.orderFrontRegardless()
        return window
    }
}

// MARK: - XDR Boost technique (multiply overlay)

@MainActor
final class XDRBoostTechnique: ExtraBrightnessTechnique {
    private(set) var isActive = false
    private(set) var currentFactor: Float = 1.0

    private var windows: [CGDirectDisplayID: (window: NSWindow, view: MTKView)] = [:]
    private var intensity: Float = 0
    private var device: MTLDevice? = MTLCreateSystemDefaultDevice()
    private var renderer: XDRBoostRenderer?

    func setIntensity(_ intensity: Float) {
        self.intensity = max(0, min(1, intensity))
        if self.intensity <= 0.001 {
            disable()
            return
        }
        if !isActive {
            enable()
        } else {
            updateClearColors()
        }
    }

    private func enable() {
        guard let device else { return }
        isActive = true
        renderer = XDRBoostRenderer(device: device)
        for screen in ExtraBrightnessSupport.xdrDisplays() {
            guard let id = screen.displayId else { continue }
            attach(screen: screen, id: id)
        }
        updateClearColors()
    }

    func disable() {
        isActive = false
        for (_, pair) in windows {
            pair.window.orderOut(nil)
            pair.window.contentView = nil
        }
        windows.removeAll()
        renderer = nil
        currentFactor = 1.0
    }

    func handleScreenChange() {
        guard isActive else { return }
        let screens = ExtraBrightnessSupport.xdrDisplays()
        let active = Set(screens.compactMap(\.displayId))
        for id in windows.keys where !active.contains(id) {
            windows[id]?.window.orderOut(nil)
            windows.removeValue(forKey: id)
        }
        for screen in screens {
            guard let id = screen.displayId else { continue }
            if let existing = windows[id] {
                existing.window.setFrame(screen.frame, display: true)
            } else {
                attach(screen: screen, id: id)
            }
        }
        updateClearColors()
    }

    func handleSleep() {}
    func handleWake() {
        guard isActive else { return }
        handleScreenChange()
        windows.values.forEach { $0.window.orderFrontRegardless() }
    }

    private func attach(screen: NSScreen, id: CGDirectDisplayID) {
        guard let device, let renderer else { return }
        let frame = screen.frame
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        let view = MTKView(frame: NSRect(origin: .zero, size: frame.size), device: device)
        view.colorPixelFormat = .rgba16Float
        view.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        view.preferredFramesPerSecond = 10
        view.clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        view.delegate = renderer
        view.autoresizingMask = [.width, .height]
        if let layer = view.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
        }
        view.wantsLayer = true
        window.contentView = view
        // Multiply with desktop behind the window (xdr-boost approach).
        window.contentView?.layer?.compositingFilter = "multiply"
        window.orderFrontRegardless()
        windows[id] = (window, view)
    }

    private func updateClearColors() {
        var peak: Float = 1
        for (id, pair) in windows {
            let screen = NSScreen.screens.first(where: { $0.displayId == id })
            let potential = Double(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 4)
            // 50% → ~2×, MAX → min(4×, potential EDR)
            let maxBoost = min(4.0, max(1.5, potential))
            let boost = 1.0 + (maxBoost - 1.0) * Double(intensity)
            pair.view.clearColor = MTLClearColor(red: boost, green: boost, blue: boost, alpha: 1)
            pair.view.draw()
            pair.window.orderFrontRegardless()
            peak = max(peak, Float(boost))
        }
        currentFactor = peak
    }
}

final class XDRBoostRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    init(device: MTLDevice) {
        commandQueue = device.makeCommandQueue()!
        super.init()
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let desc = view.currentRenderPassDescriptor,
              let buf = commandQueue.makeCommandBuffer(),
              let enc = buf.makeRenderCommandEncoder(descriptor: desc),
              let drawable = view.currentDrawable else { return }
        enc.endEncoding()
        buf.present(drawable)
        buf.commit()
    }
}

// MARK: - DisplayServices local helpers (Fullbright path)

enum DisplayServicesLocal {
    private static let handle: UnsafeMutableRawPointer? = {
        let paths = [
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices"
        ]
        for p in paths { if let h = dlopen(p, RTLD_LAZY) { return h } }
        return nil
    }()

    static func setBrightness(_ id: CGDirectDisplayID, _ value: Float) -> Bool {
        guard let sym = dlsym(handle, "DisplayServicesSetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        return unsafeBitCast(sym, to: Fn.self)(id, value) == 0
    }

    static func setLinearBrightness(_ id: CGDirectDisplayID, _ value: Float) -> Bool {
        guard let sym = dlsym(handle, "DisplayServicesSetLinearBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        return unsafeBitCast(sym, to: Fn.self)(id, value) == 0
    }

    static func setAmbientLightCompensation(_ id: CGDirectDisplayID, enabled: Bool) -> Bool {
        guard let sym = dlsym(handle, "DisplayServicesSetAmbientLightCompensationEnabled")
                ?? dlsym(handle, "DisplayServicesEnableAmbientLightCompensation") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Bool) -> Int32
        return unsafeBitCast(sym, to: Fn.self)(id, enabled) == 0
    }
}
