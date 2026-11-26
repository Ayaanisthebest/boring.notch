//
//  BoringNotchXPCHelper.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation
import ApplicationServices
import IOKit
import CoreGraphics

class BoringNotchXPCHelper: NSObject, BoringNotchXPCHelperProtocol {
    
    @objc func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void) {
        reply(AXIsProcessTrusted())
    }

    @objc func requestAccessibilityAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @objc func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void) {
        if AXIsProcessTrusted() {
            reply(true)
            return
        }

        if promptIfNeeded {
            requestAccessibilityAuthorization()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            reply(AXIsProcessTrusted())
        }
    }
    
    private class KeyboardBrightnessClient {
        private static let keyboardID: UInt64 = 1
        private var clientInstance: NSObject?
        private let getSelector = NSSelectorFromString("brightnessForKeyboard:")
        private let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")

        init() {
            var loaded = false
            let bundlePaths = [
                "/System/Library/PrivateFrameworks/CoreBrightness.framework",
                "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
            ]
            for path in bundlePaths where !loaded {
                if let bundle = Bundle(path: path) {
                    loaded = bundle.load()
                }
            }
            if loaded, let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
                clientInstance = cls.init()
            }
        }

        var isAvailable: Bool { clientInstance != nil }

        func currentBrightness() -> Float? {
            guard let clientInstance,
                  let fn: BrightnessGetter = methodIMP(on: clientInstance, selector: getSelector, as: BrightnessGetter.self)
            else { return nil }
            return fn(clientInstance, getSelector, Self.keyboardID)
        }

        func setBrightness(_ value: Float) -> Bool {
            guard let clientInstance,
                  let fn: BrightnessSetter = methodIMP(on: clientInstance, selector: setSelector, as: BrightnessSetter.self)
            else { return false }
            return fn(clientInstance, setSelector, value, Self.keyboardID).boolValue
        }

        private typealias BrightnessGetter = @convention(c) (NSObject, Selector, UInt64) -> Float
        private typealias BrightnessSetter = @convention(c) (NSObject, Selector, Float, UInt64) -> ObjCBool

        private func methodIMP<T>(on object: NSObject, selector: Selector, as type: T.Type) -> T? {
            guard let cls = object_getClass(object),
                  let method = class_getInstanceMethod(cls, selector)
            else { return nil }
            let imp = method_getImplementation(method)
            return unsafeBitCast(imp, to: type)
        }
    }

    private static let keyboardClient = KeyboardBrightnessClient()

    @objc func isKeyboardBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.isAvailable)
    }

    @objc func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void) {
        reply(Self.keyboardClient.currentBrightness().map { NSNumber(value: $0) })
    }

    @objc func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.setBrightness(value))
    }

    // MARK: - Screen Brightness (moved from client app into helper)

    @objc func isScreenBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        guard let displayID = brightnessDisplayID() else {
            reply(false)
            return
        }
        var b: Float = 0
        reply(displayServicesGetBrightness(displayID: displayID, out: &b) || ioServiceFor(displayID: displayID) != nil)
    }

    @objc func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void) {
        guard let displayID = brightnessDisplayID() else {
            reply(nil)
            return
        }
        var b: Float = 0
        if displayServicesGetBrightness(displayID: displayID, out: &b) {
            reply(NSNumber(value: b))
            return
        }
        if let io = ioServiceFor(displayID: displayID) {
            var level: Float = 0
            if IODisplayGetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, &level) == kIOReturnSuccess {
                IOObjectRelease(io)
                reply(NSNumber(value: level))
                return
            }
            IOObjectRelease(io)
        }
        reply(nil)
    }

    /// Cancels in-flight absolute settle work when the user keeps adjusting brightness.
    private var brightnessSettleWorkItem: DispatchWorkItem?
    private let brightnessQueue = DispatchQueue(label: "boringnotch.brightness", qos: .userInteractive)

    @objc func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        let clamped = max(0, min(1, value))
        guard let displayID = brightnessDisplayID() else {
            reply(false)
            return
        }

        var current: Float = 0
        let canRead = displayServicesGetBrightness(displayID: displayID, out: &current)
        let canChange = displayServicesCanChangeBrightness(displayID: displayID)

        if canRead || canChange {
            // Kick a hardware ramp first (same path macOS uses). Do NOT immediately
            // follow with SetBrightness — that cancels the smooth transition.
            var startedSmooth = false
            if canRead {
                let delta = clamped - current
                if abs(delta) > 0.0005, displayServicesSupportsSmoothBrightness() {
                    // Return codes for Smooth aren't well documented; if the symbol
                    // exists, invoke it and settle absolute brightness shortly after.
                    _ = displayServicesSetBrightnessSmooth(displayID: displayID, delta: delta)
                    startedSmooth = true
                }
            }

            if startedSmooth {
                scheduleBrightnessSettle(displayID: displayID, value: clamped)
                reply(true)
                return
            }

            // Instant fallback when Smooth isn't available or delta is tiny.
            if applyAbsoluteBrightness(displayID: displayID, value: clamped) {
                reply(true)
                return
            }
        }

        if let io = ioServiceFor(displayID: displayID) {
            let ok = IODisplaySetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, clamped) == kIOReturnSuccess
            IOObjectRelease(io)
            reply(ok)
            return
        }
        reply(false)
    }

    private func scheduleBrightnessSettle(displayID: CGDirectDisplayID, value: Float) {
        brightnessSettleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.applyAbsoluteBrightness(displayID: displayID, value: value)
        }
        brightnessSettleWorkItem = work
        // Match ~macOS ramp length; retargeting mid-ramp cancels the previous settle.
        brightnessQueue.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    @discardableResult
    private func applyAbsoluteBrightness(displayID: CGDirectDisplayID, value: Float) -> Bool {
        let ok = displayServicesSetBrightness(displayID: displayID, value: value)
        // User brightness of 1.0 alone often leaves headroom on Apple displays —
        // SetLinearBrightness is required to actually hit full.
        if value >= 0.999 {
            _ = displayServicesSetLinearBrightness(displayID: displayID, value: 1.0)
        } else if value <= 0.001 {
            _ = displayServicesSetLinearBrightness(displayID: displayID, value: 0.0)
        }
        return ok
    }

    // MARK: - Private helpers for DisplayServices / IOKit access

    /// Prefer a controllable built-in display; fall back to main / any DisplayServices display.
    private func brightnessDisplayID() -> CGDirectDisplayID? {
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            let main = CGMainDisplayID()
            return main == kCGNullDirectDisplay ? nil : main
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetOnlineDisplayList(displayCount, &displays, &displayCount) == .success else {
            let main = CGMainDisplayID()
            return main == kCGNullDirectDisplay ? nil : main
        }

        let online = Array(displays.prefix(Int(displayCount)))

        if let builtIn = online.first(where: {
            CGDisplayIsBuiltin($0) != 0 && displayServicesCanChangeBrightness(displayID: $0)
        }) {
            return builtIn
        }

        if let builtIn = online.first(where: { CGDisplayIsBuiltin($0) != 0 }) {
            var b: Float = 0
            if displayServicesGetBrightness(displayID: builtIn, out: &b) || ioServiceFor(displayID: builtIn) != nil {
                return builtIn
            }
        }

        let main = CGMainDisplayID()
        if main != kCGNullDirectDisplay {
            var b: Float = 0
            if displayServicesCanChangeBrightness(displayID: main)
                || displayServicesGetBrightness(displayID: main, out: &b) {
                return main
            }
        }

        if let controllable = online.first(where: { displayServicesCanChangeBrightness(displayID: $0) }) {
            return controllable
        }

        if let readable = online.first(where: {
            var b: Float = 0
            return displayServicesGetBrightness(displayID: $0, out: &b)
        }) {
            return readable
        }

        return main != kCGNullDirectDisplay ? main : nil
    }

    private func displayServicesGetBrightness(displayID: CGDirectDisplayID, out: inout Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesGetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        var tmp: Float = 0
        let r = fn(displayID, &tmp)
        if r == 0 { out = tmp; return true }
        return false
    }

    private func displayServicesSetBrightness(displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, value) == 0
    }

    /// Hardware ramp. Lunar passes a delta (target − current), not an absolute level.
    private func displayServicesSetBrightnessSmooth(displayID: CGDirectDisplayID, delta: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightnessSmooth") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, delta) == 0
    }

    private func displayServicesSupportsSmoothBrightness() -> Bool {
        dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightnessSmooth") != nil
    }

    private func displayServicesSetLinearBrightness(displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetLinearBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, value) == 0
    }

    private func displayServicesCanChangeBrightness(displayID: CGDirectDisplayID) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesCanChangeBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID) -> Bool
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID)
    }

    private func ioServiceFor(displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let info = IODisplayCreateInfoDictionary(service, 0).takeRetainedValue() as NSDictionary
            if let vendorID = info[kDisplayVendorID] as? UInt32,
               let productID = info[kDisplayProductID] as? UInt32,
               vendorID == CGDisplayVendorNumber(displayID),
               productID == CGDisplayModelNumber(displayID) {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }

    // MARK: - Helper handle for private framework
    private enum DisplayServicesHandle {
        static let handle: UnsafeMutableRawPointer? = {
            let paths = [
                "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices"
            ]
            for p in paths {
                if let h = dlopen(p, RTLD_LAZY) { return h }
            }
            return nil
        }()
    }
}
