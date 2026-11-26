//  BrightnessManager.swift
//  boringNotch
//
//  Created by JeanLouis on 08/22/24.

import AppKit
import Defaults

final class BrightnessManager: ObservableObject {
	static let shared = BrightnessManager()

	@Published private(set) var rawBrightness: Float = 0
	@Published private(set) var animatedBrightness: Float = 0
	@Published private(set) var lastChangeAt: Date = .distantPast

	private let visibleDuration: TimeInterval = 1.2
	private let trackedValueFreshness: TimeInterval = 2.0
	private let stepCount: Float = 16
	private let client = XPCHelperClient.shared
	/// Serializes key-repeat adjustments so holds don't race mid-await.
	private var adjustChain: Task<Void, Never>?

	private init() { refresh() }

	var shouldShowOverlay: Bool { Date().timeIntervalSince(lastChangeAt) < visibleDuration }

	/// HUD bar value stays at 1.0 in XDR; level is shown as text ("50%" / "MAX").
	@MainActor
	var displayBrightness: Float {
		ExtraBrightnessManager.shared.intensity > 0.001 ? 1.0 : rawBrightness
	}

	@MainActor
	var isInXDR: Bool {
		ExtraBrightnessManager.shared.intensity > 0.001
	}

	/// Trailing label for the two XDR steps.
	@MainActor
	var xdrHUDLabel: String? {
		let intensity = ExtraBrightnessManager.shared.intensity
		if intensity >= 0.999 { return "MAX" }
		if intensity >= 0.25 { return "50%" }
		return nil
	}

	func refresh() {
		Task { @MainActor in
			if let current = await client.currentScreenBrightness() {
				publish(brightness: current, touchDate: false)
			}
		}
	}

	@MainActor func setRelative(delta: Float) {
		let previous = adjustChain
		adjustChain = Task { @MainActor [weak self] in
			_ = await previous?.value
			guard let self else { return }
			let hudValue = await self.adjustRelative(delta: delta)
			let xdrIcon = self.isInXDR ? (self.xdrHUDLabel ?? "XDR") : ""
			BoringViewCoordinator.shared.toggleSneakPeek(
				status: true,
				type: .brightness,
				value: CGFloat(hudValue),
				icon: xdrIcon
			)
		}
	}

	/// Continuous brightness: SDR 0→1, then XDR intensity 0→1 on further ups.
	@MainActor
	@discardableResult
	func adjustRelative(delta: Float) async -> Float {
		let extra = ExtraBrightnessManager.shared
		extra.refreshSupport()

		let starting = await resolvedStartingBrightness()
		let levels: Float = abs(delta) < (1 / 32) ? 64 : stepCount
		let direction: Float = delta >= 0 ? 1 : -1
		let stepsToMove = max(1, Int((abs(delta) / (1 / levels)).rounded()))
		let sdrTarget = steppedTarget(from: starting, delta: delta)

		// Already in / entering XDR headroom while dimming — only two steps: MAX → 50% → off.
		if direction < 0, extra.intensity > 0.001 {
			if extra.intensity >= 0.999 {
				extra.setIntensity(0.5)
			} else {
				extra.setIntensity(0)
			}
			publish(brightness: 1.0, touchDate: true)
			return displayBrightness
		}

		// SDR cannot go higher → climb XDR in two steps: 50% then MAX.
		let atSdrMax = max(starting, rawBrightness) >= 0.98
			|| (direction > 0 && sdrTarget >= 0.999 && abs(sdrTarget - starting) < 0.0001)
		if direction > 0, atSdrMax, extra.isSupported {
			if !Defaults[.extraBrightnessEnabled] {
				Defaults[.extraBrightnessEnabled] = true
			}
			if starting < 0.999 || rawBrightness < 0.999 {
				_ = await client.setScreenBrightness(1.0)
			}
			publish(brightness: 1.0, touchDate: true)
			if extra.intensity < 0.25 {
				extra.setIntensity(0.5)
			} else if extra.intensity < 0.999 {
				extra.setIntensity(1.0)
			}
			return displayBrightness
		}

		let ok = await client.setScreenBrightness(sdrTarget)
		if ok {
			if sdrTarget < 0.98, extra.intensity > 0 {
				extra.setIntensity(0)
			}
			publish(brightness: sdrTarget, touchDate: true)
			return sdrTarget
		} else {
			refresh()
			return rawBrightness
		}
	}

	func setAbsolute(value: Float) {
		let clamped = max(0, min(1, value))
		Task { @MainActor in
			if clamped < 0.98 {
				ExtraBrightnessManager.shared.setIntensity(0)
			}
			let ok = await client.setScreenBrightness(clamped)
			if ok {
				publish(brightness: clamped, touchDate: true)
			} else {
				refresh()
			}
		}
	}

	private func resolvedStartingBrightness() async -> Float {
		// Prefer our last committed value while keys are repeating.
		if Date().timeIntervalSince(lastChangeAt) < trackedValueFreshness {
			return rawBrightness
		}
		return await client.currentScreenBrightness() ?? rawBrightness
	}

	private func steppedTarget(from starting: Float, delta: Float) -> Float {
		let levels: Float = abs(delta) < (1 / 32) ? 64 : stepCount
		let stepSize = 1 / levels
		let direction: Float = delta >= 0 ? 1 : -1
		let stepsToMove = max(1, Int((abs(delta) / stepSize).rounded()))
		let currentStep = (starting * levels).rounded()
		let nextStep = max(0, min(levels, currentStep + direction * Float(stepsToMove)))
		return nextStep / levels
	}

	@MainActor
	private func publish(brightness: Float, touchDate: Bool) {
		if rawBrightness != brightness || touchDate {
			if touchDate { lastChangeAt = Date() }
			rawBrightness = brightness
			animatedBrightness = brightness
		}
	}
}

// MARK: - Keyboard Backlight Controller
final class KeyboardBacklightManager: ObservableObject {
	static let shared = KeyboardBacklightManager()

	@Published private(set) var rawBrightness: Float = 0
	@Published private(set) var lastChangeAt: Date = .distantPast

	private let visibleDuration: TimeInterval = 1.2
	private let trackedValueFreshness: TimeInterval = 2.0
	private let stepCount: Float = 16
	private let client = XPCHelperClient.shared

	private init() { refresh() }

	var shouldShowOverlay: Bool { Date().timeIntervalSince(lastChangeAt) < visibleDuration }

	func refresh() {
		Task { @MainActor in
			if let current = await client.currentKeyboardBrightness() {
				publish(brightness: current, touchDate: false)
			}
		}
	}

	@MainActor func setRelative(delta: Float) {
		Task { @MainActor in
			let starting = await resolvedStartingBrightness()
			let target = steppedTarget(from: starting, delta: delta)
			let ok = await client.setKeyboardBrightness(target)
			if ok {
				publish(brightness: target, touchDate: true)
				BoringViewCoordinator.shared.toggleSneakPeek(
					status: true,
					type: .backlight,
					value: CGFloat(target)
				)
			} else {
				refresh()
			}
		}
	}

	func setAbsolute(value: Float) {
		let clamped = max(0, min(1, value))
		Task { @MainActor in
			let ok = await client.setKeyboardBrightness(clamped)
			if ok {
				publish(brightness: clamped, touchDate: true)
			} else {
				refresh()
			}
		}
	}

	private func resolvedStartingBrightness() async -> Float {
		if Date().timeIntervalSince(lastChangeAt) < trackedValueFreshness {
			return rawBrightness
		}
		return await client.currentKeyboardBrightness() ?? rawBrightness
	}

	private func steppedTarget(from starting: Float, delta: Float) -> Float {
		let levels: Float = abs(delta) < (1 / 32) ? 64 : stepCount
		let stepSize = 1 / levels
		let direction: Float = delta >= 0 ? 1 : -1
		let stepsToMove = max(1, Int((abs(delta) / stepSize).rounded()))
		let currentStep = (starting * levels).rounded()
		let nextStep = max(0, min(levels, currentStep + direction * Float(stepsToMove)))
		return nextStep / levels
	}

	@MainActor
	private func publish(brightness: Float, touchDate: Bool) {
		if rawBrightness != brightness || touchDate {
			if touchDate { lastChangeAt = Date() }
			rawBrightness = brightness
		}
	}
}
