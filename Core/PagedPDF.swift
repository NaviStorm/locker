import CoreGraphics
import CryptoKit
import Foundation

/// Core Graphics requests plaintext ranges from authenticated blocks. No plaintext backing file exists.
private final class EncryptedRanges {
    struct Frame {
        let plain: Int64
        let sealed: UInt64
        let size: Int
    }
    let gate: SessionGate
    let size: Int64
    private let id: UUID
    private let key: SymmetricKey
    private let file: FileHandle
    private var frames: [Frame] = []
    private let mutex = NSLock()
    private var cached = Data()
    private var cachedIndex = -1
    private(set) var failed = false

    init(id: UUID, info: Document, file url: URL, gate: SessionGate) throws {
        self.id = id
        self.gate = gate
        size = info.size
        key = SymmetricKey(data: info.key)
        file = try FileHandle(forReadingFrom: url)
        var plain: Int64 = 0
        var sealed: UInt64 = 4
        try BlockCipher.decrypt(id: id, info: info, from: url, gate: gate) { bytes in
            frames.append(Frame(plain: plain, sealed: sealed, size: bytes.count))
            plain += Int64(bytes.count)
            sealed += UInt64(bytes.count + BlockCipher.overhead + 4)
        }
    }

    func copy(into target: UnsafeMutableRawPointer, position: Int64, count: Int) -> Int {
        mutex.withLock {
            do {
                try gate.check()
                guard position >= 0, position < size, count > 0 else { return 0 }
                var low = 0
                var high = frames.count
                while low < high {
                    let mid = low + (high - low) / 2
                    if frames[mid].plain <= position { low = mid + 1 } else { high = mid }
                }
                var index = max(0, low - 1)
                var copied = 0
                while index < frames.count && copied < count {
                    try gate.check()
                    let frame = frames[index]
                    if cachedIndex != index {
                        try file.seek(toOffset: frame.sealed)
                        let sealed = try BlockCipher.readExactly(frame.size + BlockCipher.overhead, from: file)
                        cached = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key,
                                                  authenticating: BlockCipher.aad(id, UInt64(index)))
                        cachedIndex = index
                    }
                    let offset = Int(position + Int64(copied) - frame.plain)
                    let length = min(count - copied, frame.size - offset)
                    guard length > 0 else { throw VaultError.damaged }
                    try gate.authorized {
                        cached.withUnsafeBytes { bytes in
                            target.advanced(by: copied).copyMemory(from: bytes.baseAddress!.advanced(by: offset), byteCount: length)
                        }
                    }
                    copied += length
                    index += 1
                }
                return copied
            } catch { failed = true; return 0 }
        }
    }

    func provider() throws -> CGDataProvider {
        let retained = Unmanaged.passRetained(self)
        var callbacks = CGDataProviderDirectCallbacks(version: 0, getBytePointer: nil, releaseBytePointer: nil,
            getBytesAtPosition: { context, destination, position, count in
                guard let context else { return 0 }
                return Unmanaged<EncryptedRanges>.fromOpaque(context).takeUnretainedValue()
                    .copy(into: destination, position: position, count: count)
            }, releaseInfo: { context in
                if let context { Unmanaged<EncryptedRanges>.fromOpaque(context).release() }
            })
        guard let provider = CGDataProvider(directInfo: retained.toOpaque(), size: size, callbacks: &callbacks) else {
            retained.release()
            throw VaultError.damaged
        }
        return provider
    }
}

actor PagedPDF {
    private let document: CGPDFDocument
    private let source: EncryptedRanges
    nonisolated let pages: Int

    init(id: UUID, info: Document, file: URL, gate: SessionGate) throws {
        let ranges = try EncryptedRanges(id: id, info: info, file: file, gate: gate)
        guard let doc = try CGPDFDocument(ranges.provider()), doc.numberOfPages > 0, !ranges.failed else {
            throw TransportError(message: "Ce PDF est illisible ou exige son propre mot de passe.")
        }
        source = ranges
        document = doc
        pages = doc.numberOfPages
    }

    func render(_ number: Int) throws -> CGImage {
        try source.gate.check()
        guard let page = document.page(at: number) else { throw VaultError.unavailable }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0, box.width.isFinite, box.height.isFinite else { throw VaultError.damaged }
        let longest = max(box.width, box.height)
        let rotated = abs(page.rotationAngle % 180) == 90
        let width = max(1, Int((rotated ? box.height : box.width) / longest * 1800))
        let height = max(1, Int((rotated ? box.width : box.height) / longest * 1800))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw VaultError.unavailable }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(bounds)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        try source.gate.check()
        guard !source.failed, let image = context.makeImage() else { throw VaultError.damaged }
        return image
    }
}

extension VaultStore {
    func pagedPDF(_ id: UUID) throws -> PagedPDF {
        try gate.check()
        guard let info = entries[id]?.document else { throw VaultError.unavailable }
        return try PagedPDF(id: id, info: info, file: blob(id), gate: gate)
    }
}
