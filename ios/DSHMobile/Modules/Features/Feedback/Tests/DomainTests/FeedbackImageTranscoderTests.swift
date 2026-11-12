@testable import DSHFeedbackDomain
import CoreGraphics
import Foundation
import ImageIO
import RelayKit
import UniformTypeIdentifiers
import XCTest

/// ImageIO 转码器（设计 §5 A2 / 用例 IMG-ENC-06…08、IMG-ORG-01…05）。
///
/// 前置统一为：源图由用例在内存里合成（不读相册、不落用户目录）；断言看**产物**——
/// 像素尺寸、类型、字节数、有没有 GPS/EXIF。
final class FeedbackImageTranscoderTests: XCTestCase {

    private let limits = FeedbackAttachmentLimits(
        maxPerMessage: 8, maxFileBytes: 8 * 1024 * 1024, maxTotalBytes: 24 * 1024 * 1024,
        types: ["jpeg", "png"], roles: ["original", "preview"])

    // MARK: - 夹具

    /// 纯色（或噪声）位图。`noise` 让 PNG/JPEG 压不小，用于"超预算"用例。
    private func makeImage(width: Int, height: Int, alpha: Bool,
                           noise: Bool = false) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let alphaInfo: CGImageAlphaInfo = alpha ? .premultipliedLast : .noneSkipLast
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: colorSpace, bitmapInfo: alphaInfo.rawValue)!
        if noise {
            let buffer = context.data!.bindMemory(to: UInt8.self,
                                                  capacity: width * height * 4)
            var seed: UInt32 = 0x1234_5678
            for index in 0..<(width * height * 4) {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                buffer[index] = UInt8((seed >> 16) & 0xFF)
            }
        } else {
            context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: alpha ? 0.5 : 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return context.makeImage()!
    }

    private func encode(_ image: CGImage, type: UTType, quality: CGFloat = 0.9,
                        properties: [CFString: Any] = [:]) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            output, type.identifier as CFString, 1, nil)!
        var props = properties
        if type == .jpeg {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// 源图属性里带 GPS + EXIF + orientation=6 的 JPEG（"手机原图"的样子）。
    private func jpegWithMetadata(width: Int, height: Int) -> Data {
        let image = makeImage(width: width, height: height, alpha: false)
        return encode(image, type: .jpeg, quality: 0.9, properties: [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 39.9,
                kCGImagePropertyGPSLongitude: 116.4,
            ] as [CFString: Any],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:11:12 09:00:00",
            ] as [CFString: Any],
            kCGImagePropertyOrientation: 6,
        ])
    }

    private func properties(of data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any])
    }

    private func hasAlpha(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// 把字节补齐到指定长度（JPEG/PNG 解码器忽略尾部多余字节）。
    private func padded(_ data: Data, to size: Int) -> Data {
        guard data.count < size else { return data }
        return data + Data(repeating: 0x00, count: size - data.count)
    }

    // MARK: - 预览（IMG-ENC-06/07）

    func testABigScreenshotGetsASmallPreviewAndTheSameOriginalPixels() async throws {
        // iOS 截图是**无 alpha** 的 PNG：预览走 JPEG，原图保留 PNG。
        let source = encode(makeImage(width: 3000, height: 6000, alpha: false), type: .png)
        let prepared = try await FeedbackImageTranscoder.prepare(
            data: source, name: "截屏.png", limits: limits)

        XCTAssertLessThanOrEqual(max(prepared.preview.pixelWidth, prepared.preview.pixelHeight),
                                 2560, "预览长边不超过 2560 真实像素")
        XCTAssertEqual(prepared.preview.contentType, "image/jpeg")
        XCTAssertLessThanOrEqual(prepared.preview.byteSize, 512 * 1024)
        XCTAssertEqual(max(prepared.original!.pixelWidth, prepared.original!.pixelHeight),
                       6000, "原图像素尺寸不变")
        XCTAssertLessThanOrEqual(prepared.original!.byteSize, limits.maxFileBytes)
        XCTAssertNil(try properties(of: prepared.preview.data)[kCGImagePropertyGPSDictionary],
                     "预览不许带 GPS")
        XCTAssertNil(try properties(of: prepared.original!.data)[kCGImagePropertyGPSDictionary],
                     "原图不许带 GPS")
    }

    func testAPNGWithoutAlphaGetsAJPEGPreviewButKeepsTheLosslessOriginal() async throws {
        let source = encode(makeImage(width: 1200, height: 800, alpha: false), type: .png)
        let prepared = try await FeedbackImageTranscoder.prepare(
            data: source, name: "纯色.png", limits: limits)

        XCTAssertEqual(prepared.preview.contentType, "image/jpeg", "无 alpha 的 PNG 预览走 JPEG")
        XCTAssertEqual(prepared.original?.contentType, "image/png", "原图仍是无损 PNG")
        XCTAssertEqual(prepared.original?.pixelWidth, 1200)
    }

    func testAPhotoWithGPSLosesItInBothCopiesAndBakesTheOrientation() async throws {
        let source = jpegWithMetadata(width: 1600, height: 1200)
        XCTAssertNotNil(try properties(of: source)[kCGImagePropertyGPSDictionary],
                        "夹具必须真的带 GPS，否则用例没有意义")

        let prepared = try await FeedbackImageTranscoder.prepare(
            data: source, name: "IMG.jpg", limits: limits)
        for data in [prepared.preview.data, prepared.original!.data] {
            let props = try properties(of: data)
            XCTAssertNil(props[kCGImagePropertyGPSDictionary])
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            XCTAssertNil(exif[kCGImagePropertyExifDateTimeOriginal], "拍摄时间不许留着")
            let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
            XCTAssertEqual(orientation, 1, "方向已经烘焙进像素")
        }
        // orientation=6 是"顺时针 90°"：宽高互换之后才是真实显示尺寸。
        XCTAssertEqual(prepared.original?.pixelWidth, 1200)
        XCTAssertEqual(prepared.original?.pixelHeight, 1600)
    }

    // MARK: - 原图预算（IMG-ORG-01/02/03）

    func testACleanImageUnderTheCapIsPassedThroughByteForByte() async throws {
        let source = padded(encode(makeImage(width: 200, height: 200, alpha: false), type: .png),
                            to: 256 * 1024)
        let tight = FeedbackAttachmentLimits(maxPerMessage: 8, maxFileBytes: source.count,
                                             maxTotalBytes: 8 * 1024 * 1024,
                                             types: ["jpeg"], roles: ["original", "preview"])
        let prepared = try await FeedbackImageTranscoder.prepare(
            data: source, name: "clean.jpg", limits: tight)

        XCTAssertTrue(prepared.originalIsPassthrough)
        XCTAssertEqual(prepared.original?.data, source, "逐字节直通")
        XCTAssertEqual(prepared.original?.byteSize, source.count)
        XCTAssertEqual(prepared.original?.contentType, "image/png")
    }

    func testAnImageOverTheCapIsReencodedAtTheSamePixelSize() async throws {
        let source = jpegWithMetadata(width: 1600, height: 1200)
        let tight = FeedbackAttachmentLimits(maxPerMessage: 8, maxFileBytes: 64 * 1024,
                                             maxTotalBytes: 8 * 1024 * 1024,
                                             types: ["jpeg"], roles: ["original", "preview"])
        let prepared = try await FeedbackImageTranscoder.prepare(
            data: source, name: "big.jpg", limits: tight)

        let original = try XCTUnwrap(prepared.original)
        XCTAssertFalse(prepared.originalIsPassthrough)
        XCTAssertLessThanOrEqual(original.byteSize, 64 * 1024)
        XCTAssertEqual(original.pixelWidth, 1200, "像素尺寸不变（方向已烘焙）")
        XCTAssertEqual(original.pixelHeight, 1600)
        XCTAssertEqual(original.contentType, "image/jpeg")
    }

    func testAnAlphaImageKeepsPNGAndTransparency() async throws {
        let source = encode(makeImage(width: 400, height: 300, alpha: true), type: .png)
        let tight = FeedbackAttachmentLimits(maxPerMessage: 8, maxFileBytes: 256 * 1024,
                                             maxTotalBytes: 8 * 1024 * 1024,
                                             types: ["png"], roles: ["original", "preview"])
        let prepared = try await FeedbackImageTranscoder.prepare(
            data: source, name: "透明.png", limits: tight)

        let original = try XCTUnwrap(prepared.original)
        XCTAssertEqual(original.contentType, "image/png")
        XCTAssertTrue(hasAlpha(original.data), "原图必须保留 alpha")
        XCTAssertLessThanOrEqual(original.byteSize, 256 * 1024)
    }

    func testAnAlphaImageOverTheCapShrinksInsteadOfDroppingAlpha() async throws {
        // 噪声让 PNG 压不下去：上限收紧到 256 KiB，只有缩边才能满足。
        let source = encode(makeImage(width: 1200, height: 900, alpha: true, noise: true),
                            type: .png)
        let tight = FeedbackAttachmentLimits(maxPerMessage: 8, maxFileBytes: 256 * 1024,
                                             maxTotalBytes: 8 * 1024 * 1024,
                                             types: ["png"], roles: ["original", "preview"])
        let prepared = try await FeedbackImageTranscoder.prepare(
            data: source, name: "噪声.png", limits: tight)

        let original = try XCTUnwrap(prepared.original)
        XCTAssertEqual(original.contentType, "image/png", "不许转 JPEG")
        XCTAssertTrue(hasAlpha(original.data))
        XCTAssertLessThanOrEqual(original.byteSize, 256 * 1024)
        XCTAssertLessThan(original.pixelWidth, 1200, "靠缩边满足上限")
        XCTAssertEqual(original.pixelWidth, original.pixelHeight * 4 / 3,
                       "按比例缩，长边仍是 4:3")
    }

    // MARK: - P2-7 其他元数据容器

    func testAPNGWithATextChunkIsReencodedAndLosesIt() async throws {
        let image = makeImage(width: 120, height: 80, alpha: false)
        let source = padded(encode(image, type: .png, properties: [
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGDescription: "Beijing",
            ] as [CFString: Any],
        ]), to: 0)
        let tight = FeedbackAttachmentLimits(maxPerMessage: 8, maxFileBytes: 512 * 1024,
                                             maxTotalBytes: 8 * 1024 * 1024,
                                             types: ["png"], roles: ["original", "preview"])
        let prepared = try await FeedbackImageTranscoder.prepare(
            data: source, name: "带文本.png", limits: tight)

        XCTAssertFalse(prepared.originalIsPassthrough, "PNG 文本块也算用户元数据，必须重编码")
        let props = try properties(of: prepared.original!.data)
        let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] ?? [:]
        XCTAssertNil(png[kCGImagePropertyPNGDescription], "描述文本不许留着")
        XCTAssertNil(props[kCGImagePropertyIPTCDictionary], "IPTC 不许留着")
    }

    func testAJPEGWithIPTCIsReencodedAndLosesIt() async throws {
        let image = makeImage(width: 120, height: 80, alpha: false)
        let source = encode(image, type: .jpeg, quality: 0.9, properties: [
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCCaptionAbstract: "Beijing",
            ] as [CFString: Any],
        ])
        let prepared = try await FeedbackImageTranscoder.prepare(
            data: source, name: "iptc.jpg", limits: limits)

        XCTAssertFalse(prepared.originalIsPassthrough, "带 IPTC 的源不直通")
        XCTAssertNil(try properties(of: prepared.original!.data)[kCGImagePropertyIPTCDictionary])
    }

    func testUnreadableBytesAreRejected() async {
        do {
            _ = try await FeedbackImageTranscoder.prepare(
                data: Data("not an image".utf8), name: "x.png", limits: limits)
            XCTFail("不是图片的字节必须抛错")
        } catch let error as FeedbackImageTranscoderError {
            XCTAssertEqual(error, .unsupportedFormat)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
