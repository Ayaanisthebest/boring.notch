//
//  ExtraBrightnessOverlay.swift
//  boringNotch
//
//  HDR trigger overlay adapted from the BrightIntosh approach
//  (https://github.com/niklasr22/BrightIntosh, GPL-3.0): a 1×1 Metal
//  EDR pixel that engages the display's HDR backlight path.
//

import AppKit
import MetalKit

/// Tiny Metal view that paints an extended-dynamic-range white sample.
final class ExtraBrightnessMetalView: MTKView, MTKViewDelegate {
    private let edrColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
    private var commandQueue: MTLCommandQueue?
    private var didRenderFirstFrame = false
    var onFirstFrameRendered: (() -> Void)?

    init(frame: CGRect, clearColorValue: Double = 1.6) {
        super.init(frame: frame, device: MTLCreateSystemDefaultDevice())

        guard let device else {
            fatalError("Extra brightness requires Metal")
        }

        autoResizeDrawable = false
        drawableSize = CGSize(width: 1, height: 1)
        commandQueue = device.makeCommandQueue()
        delegate = self
        colorPixelFormat = .rgba16Float
        colorspace = edrColorSpace
        setClearColorValue(clearColorValue)
        preferredFramesPerSecond = 5

        if let layer = self.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
            layer.isOpaque = false
            layer.pixelFormat = .rgba16Float
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setClearColorValue(_ value: Double) {
        clearColor = MTLClearColorMake(value, value, value, 1.0)
        draw()
    }

    func draw(in view: MTKView) {
        guard let commandQueue,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor),
              let drawable = view.currentDrawable else {
            return
        }

        renderEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.didRenderFirstFrame else { return }
                self.didRenderFirstFrame = true
                self.onFirstFrameRendered?()
                self.onFirstFrameRendered = nil
            }
        }
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

/// Borderless 1×1 window pinned to a screen corner to host the HDR sample.
final class ExtraBrightnessOverlayWindow: NSWindow {
    private var metalView: ExtraBrightnessMetalView?

    init() {
        let rect = NSRect(x: 0, y: 0, width: 1, height: 1)
        super.init(contentRect: rect, styleMask: [], backing: .buffered, defer: false)
        collectionBehavior = [.stationary, .ignoresCycle, .canJoinAllSpaces]
        level = .screenSaver
        canHide = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        alphaValue = 1
        animationBehavior = .none
        isOpaque = false
        hasShadow = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hidesOnDeactivate = false
    }

    func installMetalOverlay(clearColorValue: Double = 1.6, onFirstFrame: (() -> Void)? = nil) {
        let view = ExtraBrightnessMetalView(frame: NSRect(origin: .zero, size: frame.size), clearColorValue: clearColorValue)
        view.onFirstFrameRendered = onFirstFrame
        view.autoresizingMask = [.width, .height]
        metalView = view
        contentView = view
    }

    func setClearColorValue(_ value: Double) {
        metalView?.setClearColorValue(value)
    }
}

@MainActor
final class ExtraBrightnessOverlayController {
    private let window = ExtraBrightnessOverlayWindow()
    private(set) var screen: NSScreen

    init(screen: NSScreen) {
        self.screen = screen
        window.title = "Boring Notch Extra Brightness"
    }

    func open() {
        reposition()
        window.installMetalOverlay { [weak self] in
            self?.window.orderFrontRegardless()
        }
        window.displayIfNeeded()
        window.orderFrontRegardless()
        window.contentView?.needsDisplay = true
    }

    func update(screen: NSScreen) {
        self.screen = screen
        reposition()
        window.orderFrontRegardless()
    }

    func close() {
        window.close()
    }

    private func reposition() {
        var origin = screen.frame.origin
        origin.y += screen.frame.height - 1
        window.setFrame(NSRect(origin: origin, size: CGSize(width: 1, height: 1)), display: true)
    }
}
