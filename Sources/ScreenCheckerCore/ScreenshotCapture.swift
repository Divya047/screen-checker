import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

public enum ScreenshotCaptureError: LocalizedError {
    case windowNotFound
    case captureFailed(String)
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .windowNotFound: return "window not found in shareable content"
        case .captureFailed(let why): return "capture failed: \(why)"
        case .writeFailed: return "could not encode PNG"
        }
    }
}

public enum ScreenshotCapture {
    /// Captures a single window (by CGWindowID) to a PNG file.
    /// Tries ScreenCaptureKit (macOS 14+), falls back to `screencapture -l`.
    public static func capture(windowID: Int, to destination: URL) async throws {
        var lastError: Error = ScreenshotCaptureError.captureFailed("no capture method succeeded")
        if #available(macOS 14.0, *) {
            do {
                try await captureWithSCK(windowID: windowID, to: destination)
                return
            } catch {
                lastError = error
            }
        }
        do {
            try captureWithCLI(windowID: windowID, to: destination)
            return
        } catch {}
        throw lastError
    }

    @available(macOS 14.0, *)
    static func captureWithSCK(windowID: Int, to destination: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { Int($0.windowID) == windowID }) else {
            throw ScreenshotCaptureError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:])
        else { throw ScreenshotCaptureError.writeFailed }
        try data.write(to: destination, options: .atomic)
    }

    static func captureWithCLI(windowID: Int, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(windowID), destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ScreenshotCaptureError.captureFailed("screencapture exited \(process.terminationStatus)")
        }
    }

    // MARK: - Permission (Screen Recording TCC)

    public static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
