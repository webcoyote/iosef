import Foundation
import CoreGraphics
import ImageIO
@preconcurrency import CoreImage

/// Captures screenshots of the iOS Simulator.
/// - `captureSimulator`: IOSurface framebuffer → downscale to iOS points, returns JPEG base64 (coordinate-aligned).
/// - `captureToFile`: legacy window capture via CGWindowListCreateImage (requires visible Simulator window).
/// - `captureSnapPoints`: IOSurface framebuffer → downscale to iOS points, file or base64. Works when Simulator.app is hidden.
/// - `captureSnapPixels`: IOSurface framebuffer at native device pixels, file or base64. Works when Simulator.app is hidden.
public enum ScreenCapture {

    /// Result of a snap capture: either an on-disk path or base64 image data, plus dimensions.
    /// Base64 data (when present) is always JPEG — see `captureSnapPoints` / `captureSnapPixels`.
    public struct SnapResult: Sendable {
        public let path: String?
        public let base64: String?
        public let width: Int
        public let height: Int
    }

    private static func log(_ message: String) {
        logDiagnostic(message, prefix: "ScreenCapture")
    }

    // MARK: - Cached simctl path

    /// Resolved path to `simctl` binary, cached after first lookup.
    /// Avoids ~5-10ms `xcrun` overhead on every call.
    private static let resolvedSimctlPath: String = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["-f", "simctl"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 0,
           let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return path
        }
        // Fallback: use xcrun at call time
        return ""
    }()

    // MARK: - Shared CIContext

    /// Reusable CIContext for GPU-accelerated image processing.
    private static let ciContext: CIContext = {
        // Use default (GPU) context for best performance
        CIContext(options: [.useSoftwareRenderer: false])
    }()

    /// Captures the device framebuffer as a CGImage at native device pixel resolution.
    /// Tries IOSurface (fast private API) first; falls back to `simctl io screenshot` (TIFF).
    /// Both sources bypass the macOS Window Server and work when Simulator.app is hidden.
    /// On total failure the thrown error aggregates both underlying reasons.
    private static func captureFramebufferCGImage(udid: String) throws -> CGImage {
        let t0 = CFAbsoluteTimeGetCurrent()
        let bridge = PrivateFrameworkBridge.shared
        let device = try bridge.lookUpDevice(udid: udid)

        var ioSurfaceError: String?

        // Try IOSurface fast path first
        do {
            let result = try bridge.captureFramebufferIOSurface(device: device)
            let t1 = CFAbsoluteTimeGetCurrent()
            log("IOSurface capture: \(Int((t1 - t0) * 1000))ms (\(result.width)x\(result.height))")
            return result
        } catch {
            let t1 = CFAbsoluteTimeGetCurrent()
            ioSurfaceError = error.localizedDescription
            log("IOSurface failed (\(Int((t1 - t0) * 1000))ms): \(error.localizedDescription)")
        }

        // simctl fallback — also goes through the framebuffer, not the Window Server
        let tSimctl0 = CFAbsoluteTimeGetCurrent()
        let imageData: Data
        do {
            imageData = try captureFramebufferSimctl(udid: udid)
        } catch {
            let reasons = [ioSurfaceError.map { "IOSurface: \($0)" }, "simctl: \(error.localizedDescription)"]
                .compactMap { $0 }
                .joined(separator: "; ")
            throw CaptureError.framebufferCaptureFailed(reasons)
        }
        let tSimctl1 = CFAbsoluteTimeGetCurrent()
        log("simctl capture: \(Int((tSimctl1 - tSimctl0) * 1000))ms (\(imageData.count) bytes)")

        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CaptureError.framebufferCaptureFailed("Failed to decode simctl image data")
        }
        let tDecode = CFAbsoluteTimeGetCurrent()
        log("decode: \(Int((tDecode - tSimctl1) * 1000))ms (\(decoded.width)x\(decoded.height))")
        return decoded
    }

    /// Captures the simulator screen as a JPEG and returns base64-encoded data.
    /// Uses direct IOSurface access for speed (~3ms vs ~200ms simctl), falling back
    /// to simctl pipe if IOSurface is unavailable. Downscales to iOS point dimensions
    /// so coordinates align with `tap` and `describe`.
    public static func captureSimulator(udid: String, screenScale: Float, timeout: Duration = .seconds(5)) throws -> (base64: String, width: Int, height: Int) {
        let t0 = CFAbsoluteTimeGetCurrent()

        let scale = Double(screenScale)
        let sourceImage = try captureFramebufferCGImage(udid: udid)

        // Downscale from device pixels to iOS points + encode JPEG using CIContext
        let targetWidth = Int(round(Double(sourceImage.width) / scale))
        let targetHeight = Int(round(Double(sourceImage.height) / scale))

        let tResize0 = CFAbsoluteTimeGetCurrent()

        let ciImage = CIImage(cgImage: sourceImage)
        let scaleX = CGFloat(targetWidth) / CGFloat(sourceImage.width)
        let scaleY = CGFloat(targetHeight) / CGFloat(sourceImage.height)
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let tResize1 = CFAbsoluteTimeGetCurrent()

        // Encode directly to JPEG from CIImage (skip intermediate CGImage)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let jpegData = ciContext.jpegRepresentation(
            of: scaled,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8]
        ) else {
            throw CaptureError.jpegEncodingFailed
        }

        let tEncode = CFAbsoluteTimeGetCurrent()
        log("resize: \(Int((tResize1 - tResize0) * 1000))ms, jpeg: \(Int((tEncode - tResize1) * 1000))ms (\(jpegData.count) bytes)")

        let base64 = jpegData.base64EncodedString()
        let tTotal = CFAbsoluteTimeGetCurrent()
        log("total: \(Int((tTotal - t0) * 1000))ms (base64 \(base64.count) chars)")

        return (base64: base64, width: targetWidth, height: targetHeight)
    }

    /// Captures a screenshot and saves it to a file.
    /// Uses CGWindowListCreateImage for fast capture (no coordinate alignment needed).
    public static func captureToFile(udid: String, outputPath: String, format: String = "png") throws {
        log("Starting screenshot to file for \(udid)")

        let bridge = PrivateFrameworkBridge.shared
        let device = try bridge.lookUpDevice(udid: udid)
        let deviceName = (device as AnyObject).value(forKey: "name") as? String ?? ""

        let cgImage = try captureSimulatorWindow(deviceName: deviceName)
        log("Window captured: \(cgImage.width)x\(cgImage.height)")

        let url = URL(fileURLWithPath: outputPath)
        let uti = utiForFormat(format)

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            uti as CFString,
            1,
            nil
        ) else {
            throw CaptureError.jpegEncodingFailed
        }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.jpegEncodingFailed
        }

        try (mutableData as Data).write(to: url)
        log("Screenshot saved to \(outputPath) (\(mutableData.length) bytes)")
    }

    // MARK: - Snap (framebuffer-based file/base64 capture)

    /// Captures the simulator framebuffer at iOS point dimensions (1 px = 1 point).
    /// Output is coordinate-aligned with `tap` / `describe`. Works when Simulator.app is hidden.
    /// - If `outputPath` is nil, returns base64 JPEG data (and the written path is nil).
    /// - If `outputPath` is set, writes the file in the given format and returns path only.
    public static func captureSnapPoints(
        udid: String,
        screenScale: Float,
        outputPath: String?,
        format: String
    ) throws -> SnapResult {
        let t0 = CFAbsoluteTimeGetCurrent()
        let scale = Double(screenScale)
        let sourceImage = try captureFramebufferCGImage(udid: udid)

        let targetWidth = Int(round(Double(sourceImage.width) / scale))
        let targetHeight = Int(round(Double(sourceImage.height) / scale))
        let targetRect = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)

        let scaleX = CGFloat(targetWidth) / CGFloat(sourceImage.width)
        let scaleY = CGFloat(targetHeight) / CGFloat(sourceImage.height)
        let scaled = CIImage(cgImage: sourceImage).transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let result = try encodeScaled(ciImage: scaled, extent: targetRect, width: targetWidth, height: targetHeight, outputPath: outputPath, format: format)
        log("snap-points total: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms (\(targetWidth)x\(targetHeight))")
        return result
    }

    /// Captures the simulator framebuffer at native device pixel dimensions (no downscale).
    /// Works when Simulator.app is hidden.
    /// - If `outputPath` is nil, returns base64 JPEG data (and the written path is nil).
    /// - If `outputPath` is set, writes the file in the given format and returns path only.
    public static func captureSnapPixels(
        udid: String,
        outputPath: String?,
        format: String
    ) throws -> SnapResult {
        let t0 = CFAbsoluteTimeGetCurrent()
        let sourceImage = try captureFramebufferCGImage(udid: udid)
        let width = sourceImage.width
        let height = sourceImage.height

        if let outputPath = outputPath, format.lowercased() != "jpeg" && format.lowercased() != "jpg" {
            // Direct CGImage → CGImageDestination path: no intermediate CIImage render.
            try writeCGImageToFile(sourceImage, outputPath: outputPath, format: format)
            log("snap-pixels total: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms (\(width)x\(height))")
            return SnapResult(path: outputPath, base64: nil, width: width, height: height)
        }

        // JPEG (to file or base64) → use CIContext for consistent quality with captureSimulator.
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let ciImage = CIImage(cgImage: sourceImage)
        let result = try encodeScaled(ciImage: ciImage, extent: rect, width: width, height: height, outputPath: outputPath, format: format)
        log("snap-pixels total: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms (\(width)x\(height))")
        return result
    }

    /// Encodes a (possibly-scaled) CIImage either to a file or to base64 JPEG.
    /// - For JPEG output (file or base64), uses CIContext.jpegRepresentation — the same fast path
    ///   as `captureSimulator` (~3ms for the MCP case).
    /// - For other formats, renders to a bitmap CGImage via CIContext then encodes via CGImageDestination.
    private static func encodeScaled(
        ciImage: CIImage,
        extent: CGRect,
        width: Int,
        height: Int,
        outputPath: String?,
        format: String
    ) throws -> SnapResult {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let normalized = format.lowercased()

        // base64 path: always JPEG, matches captureSimulator's behavior.
        if outputPath == nil {
            guard let jpegData = ciContext.jpegRepresentation(
                of: ciImage,
                colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8]
            ) else {
                throw CaptureError.jpegEncodingFailed
            }
            return SnapResult(path: nil, base64: jpegData.base64EncodedString(), width: width, height: height)
        }

        let outputPath = outputPath!

        if normalized == "jpeg" || normalized == "jpg" {
            guard let jpegData = ciContext.jpegRepresentation(
                of: ciImage,
                colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]
            ) else {
                throw CaptureError.jpegEncodingFailed
            }
            try jpegData.write(to: URL(fileURLWithPath: outputPath))
            return SnapResult(path: outputPath, base64: nil, width: width, height: height)
        }

        // Render to a bitmap CGImage at the exact target dimensions, then encode with CGImageDestination.
        guard let rendered = ciContext.createCGImage(ciImage, from: extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw CaptureError.framebufferCaptureFailed("Failed to render scaled image")
        }
        try writeCGImageToFile(rendered, outputPath: outputPath, format: format)
        return SnapResult(path: outputPath, base64: nil, width: width, height: height)
    }

    private static func writeCGImageToFile(_ image: CGImage, outputPath: String, format: String) throws {
        let uti = utiForFormat(format)
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            uti as CFString,
            1,
            nil
        ) else {
            throw CaptureError.jpegEncodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.jpegEncodingFailed
        }
        try (mutableData as Data).write(to: URL(fileURLWithPath: outputPath))
    }

    // MARK: - Framebuffer Capture (simctl pipe fallback)

    /// Captures the device framebuffer via `simctl io screenshot` piped to stdout.
    /// Uses TIFF format for faster encode (no deflate compression) and direct simctl path to skip xcrun.
    private static func captureFramebufferSimctl(udid: String) throws -> Data {
        let process = Process()

        // Use cached direct simctl path to avoid xcrun overhead (~5-10ms)
        if !resolvedSimctlPath.isEmpty {
            process.executableURL = URL(fileURLWithPath: resolvedSimctlPath)
            process.arguments = ["io", udid, "screenshot", "--type=tiff", "-"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "io", udid, "screenshot", "--type=tiff", "-"]
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0, !data.isEmpty else {
            throw CaptureError.framebufferCaptureFailed(
                "simctl screenshot exited with status \(process.terminationStatus)")
        }

        return data
    }

    // MARK: - Window Capture (CGWindowListCreateImage)

    /// Captures the Simulator window for the given device via CGWindowListCreateImage.
    private static func captureSimulatorWindow(deviceName: String) throws -> CGImage {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            throw CaptureError.noSimulatorWindow(deviceName)
        }

        for window in windowList {
            guard let ownerName = window[kCGWindowOwnerName as String] as? String,
                  ownerName == "Simulator",
                  let windowName = window[kCGWindowName as String] as? String,
                  windowName.contains(deviceName),
                  let windowID = window[kCGWindowNumber as String] as? CGWindowID,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0 else {
                continue
            }

            log("Found window: '\(windowName)' (ID: \(windowID))")

            guard let image = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                windowID,
                [.boundsIgnoreFraming, .bestResolution]
            ) else {
                throw CaptureError.windowCaptureFailed(
                    "CGWindowListCreateImage returned nil. Grant Screen Recording permission in System Settings > Privacy & Security.")
            }

            return image
        }

        throw CaptureError.noSimulatorWindow(deviceName)
    }

    // MARK: - Helpers

    private static func utiForFormat(_ format: String) -> String {
        switch format.lowercased() {
        case "jpeg", "jpg": return "public.jpeg"
        case "tiff", "tif": return "public.tiff"
        case "bmp": return "com.microsoft.bmp"
        case "gif": return "com.compuserve.gif"
        default: return "public.png"
        }
    }

    public enum CaptureError: Error, LocalizedError {
        case jpegEncodingFailed
        case noSimulatorWindow(String)
        case windowCaptureFailed(String)
        case framebufferCaptureFailed(String)

        public var errorDescription: String? {
            switch self {
            case .jpegEncodingFailed:
                return "Failed to encode image"
            case .noSimulatorWindow(let name):
                return "No Simulator window found for device '\(name)'. Is the Simulator running and visible?"
            case .windowCaptureFailed(let reason):
                return "Window capture failed: \(reason)"
            case .framebufferCaptureFailed(let reason):
                return "Framebuffer capture failed: \(reason)"
            }
        }
    }
}
