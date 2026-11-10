// The user's own notes on a meeting (palaver/my_notes.py, #44): paragraphs with the meeting time they
// were started at, pasted images with the text macOS Vision read from them. Same files, same bytes:
//
// - `my-notes.json`: `[{"text", "at"}]` (`"image"` too for a pasted image), `indent=1`, not ASCII-escaped,
//   no trailing newline, written through `.my-notes.json.<8 hex>.tmp`;
// - `my-notes/`: the images (`img-<12 hex>.<ext>`) and `<image>.txt`, the text read from each;
// - `.my-notes.lock`: the flock every writer takes.
//
// Images never leave this Mac: a language model gets the text read from them, never the image.
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import os
import PalaverCore
import Vision

/// The notes changed since the editor read them; `document` is how they are now (Python: `Conflict`).
public struct MyNotesConflict: Error, CustomStringConvertible {
    public let document: JSONValue
    public var description: String { "your notes were changed elsewhere in the meantime" }
}

/// What Python raises as `ValueError` (invalid) and `FileNotFoundError` (notFound).
public enum MyNotesError: Error, CustomStringConvertible {
    case invalid(String)
    case notFound(String)

    public var description: String {
        switch self { case .invalid(let m), .notFound(let m): return m }
    }
}

public enum MyNotes {
    public static let fileName = "my-notes.json"
    public static let imagesFolder = "my-notes"
    public static let maxParagraphs = 5000
    public static let maxText = 20_000  // characters in one paragraph
    public static let maxImageBytes = 25 * 1024 * 1024
    public static let maxAt = 7 * 24 * 3600.0
    public static let contentTypes = [".png": "image/png", ".jpg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp",
                                      ".heic": "image/heic"]
    public static let languages = ["de-DE", "en-US"]
    /// An image is read scaled down to at most this wide and high.
    public static let maxReadPixels = 4096
    public static let lockName = ".my-notes.lock"

    private static let log = Logger(subsystem: "com.kenodressel.palaver", category: "my-notes")
    /// One text recognition at a time: pasting ten screenshots runs them in turn.
    private static let reading = NSLock()
    private static let imageExtensions: Set<String> = ["png", "jpg", "gif", "webp", "heic"]

    // MARK: - One paragraph

    /// One paragraph as saved: `at` is the meeting time in seconds (one decimal), or nil.
    public struct Paragraph: Equatable {
        public var text: String
        public var at: Double?
        public var image: String?

        public init(text: String, at: Double? = nil, image: String? = nil) {
            self.text = text
            self.at = at
            self.image = image
        }

        /// `{"text", "at"}` and `"image"` last, an `at` that is a whole number written as an int.
        public var json: JSONValue {
            var fields: [(String, JSONValue)] = [("text", .string(text)), ("at", Paragraph.atJSON(at))]
            if let image { fields.append(("image", .string(image))) }
            return .object(fields)
        }

        static func atJSON(_ at: Double?) -> JSONValue {
            guard let at else { return .null }
            return at == at.rounded(.towardZero) ? .int(Int(at)) : .double(at)
        }
    }

    /// `_paragraph`: the validated paragraph, or ValueError's message.
    static func paragraph(_ p: JSONValue, in folder: URL, checkImage: Bool = true) throws -> Paragraph {
        guard case .object = p else { throw MyNotesError.invalid(cut("a paragraph is not an object: \(pyRepr(p))")) }
        guard case .string(let text)? = p["text"] else { throw MyNotesError.invalid("a paragraph without its text") }
        if text.unicodeScalars.count > maxText { throw MyNotesError.invalid("a paragraph is longer than 20,000 characters") }
        var at: Double?
        if let raw = p["at"], !raw.isNull {
            let value: Double
            switch raw {
            case .int(let i): value = Double(i)
            case .double(let d): value = d
            default: throw MyNotesError.invalid(cut("not a meeting time: \(pyRepr(raw))"))
            }
            guard value.isFinite, value >= 0, value <= maxAt else { throw MyNotesError.invalid(cut("not a meeting time: \(pyRepr(raw))")) }
            at = Py.round(value, 1)
        }
        var image: String?
        if let raw = p["image"], !raw.isNull {
            guard case .string(let name) = raw, isImageName(name) else {
                throw MyNotesError.invalid(cut("not an image of these notes: \(pyRepr(raw))"))
            }
            if checkImage && !isFile(imageURL(folder, name)) { throw MyNotesError.invalid("no image \(name)") }
            image = name
        }
        return Paragraph(text: text, at: at, image: image)
    }

    /// `_paragraph` again over a paragraph already read: times rounded alike, none out of range.
    private static func renormalized(_ p: Paragraph) throws -> Paragraph {
        try paragraph(p.json, in: URL(fileURLWithPath: "/"), checkImage: false)
    }

    static func hasContent(_ paragraphs: [Paragraph]) -> Bool {
        paragraphs.contains { !Py.strip($0.text).isEmpty || $0.image != nil }
    }

    /// `img-[0-9a-f]{12}\.(?:png|jpg|gif|webp|heic)` as a full match.
    public static func isImageName(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        guard bytes.count > 17, bytes.starts(with: Array("img-".utf8)), bytes[16] == UInt8(ascii: ".") else { return false }
        let hex = bytes[4..<16].allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
        return hex && imageExtensions.contains(String(decoding: bytes[17...], as: UTF8.self))
    }

    // MARK: - Paths and the lock

    static func fileURL(_ folder: URL) -> URL { folder.appendingPathComponent(fileName) }
    static func imagesURL(_ folder: URL) -> URL { folder.appendingPathComponent(imagesFolder, isDirectory: true) }
    static func imageURL(_ folder: URL, _ name: String) -> URL { imagesURL(folder).appendingPathComponent(name) }
    static func textURL(_ folder: URL, _ name: String) -> URL { imagesURL(folder).appendingPathComponent("\(name).txt") }

    /// One writer of a folder's notes at a time, across processes (the window's server, the processing run
    /// matching the calendar event, a join after a restart): an flock on `.my-notes.lock` in the folder.
    /// Taken again by the same thread, it is already held.
    public static func locked<T>(_ folder: URL, _ body: () throws -> T) throws -> T {
        try StoreLock.with(folder.appendingPathComponent(".my-notes"), body)
    }

    private static func both<T>(_ a: URL, _ b: URL, _ body: () throws -> T) throws -> T {
        try StoreLock.both(a.appendingPathComponent(".my-notes"), b.appendingPathComponent(".my-notes"), body)
    }

    /// Changes whenever the notes do; "" for none: the first 16 hex digits of the file's sha256.
    public static func revision(_ folder: URL) -> String {
        guard let data = try? Data(contentsOf: fileURL(folder)) else { return "" }
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The document

    /// The paragraphs; none when there are no notes (or a file no longer readable: the paragraphs that
    /// still make sense are kept).
    public static func load(_ folder: URL) -> [Paragraph] {
        guard let raw = PythonJSON.read(fileURL(folder))?.arrayValue else { return [] }
        return raw.compactMap { try? paragraph($0, in: folder, checkImage: false) }
    }

    /// Replaces the document (validated: garbage throws `MyNotesError.invalid` and changes nothing). A
    /// document with nothing in it leaves no file. `base`: the revision the editor read; when the notes
    /// changed since, `MyNotesConflict` (with them as they are now) and nothing is written. Answers
    /// `{"paragraphs", "revision"}`.
    public static func save(_ folder: URL, paragraphs: JSONValue, base: String? = nil) throws -> JSONValue {
        guard case .array(let items) = paragraphs else { throw MyNotesError.invalid("the notes are not a list of paragraphs") }
        if items.count > maxParagraphs { throw MyNotesError.invalid("more than \(maxParagraphs) paragraphs") }
        let clean = try items.map { try paragraph($0, in: folder) }
        return try locked(folder) {
            if let base, base != revision(folder) { throw MyNotesConflict(document: document(folder)) }
            try write(folder, clean)
            return .object([("paragraphs", .array(clean.map(\.json))), ("revision", .string(revision(folder)))])
        }
    }

    /// Paragraphs taken out (an image deleted, the notes cleared) back into the notes as they are now,
    /// whatever was written since: after `after` when it is still there, else by time (those without
    /// one before the first with one). Paragraphs already there are not put in twice.
    public static func putBack(_ folder: URL, _ paragraphs: [JSONValue], after: JSONValue? = nil) throws {
        try locked(folder) {
            var current = load(folder)
            var anchor: Int?
            if let after, !after.isNull, let k = current.firstIndex(where: { $0.json == after }) { anchor = k + 1 }
            var untimed = 0
            for raw in paragraphs {
                let p = try paragraph(raw, in: folder, checkImage: false)
                if current.contains(p) { continue }
                var i: Int
                if let a = anchor {
                    i = a
                    anchor = a + 1
                } else if p.at == nil {
                    i = current.firstIndex { $0.at != nil } ?? current.count
                    if untimed != 0 { i = min(i, untimed) }
                    untimed = i + 1
                } else {
                    let timed = current.indices.filter { current[$0].at != nil }
                    if let later = timed.first(where: { current[$0].at! > p.at! }) {
                        i = later
                    } else {
                        i = timed.last.map { $0 + 1 } ?? current.count
                    }
                }
                current.insert(p, at: i)
            }
            try write(folder, current)
        }
    }

    private static func write(_ folder: URL, _ paragraphs: [Paragraph]) throws {
        let normal = try paragraphs.map(renormalized)  // times rounded alike
        if hasContent(normal) {
            let text = PythonJSON.dumps(.array(normal.map(\.json)), indent: 1, ensureAscii: false)
            try writeAtomic(fileURL(folder), text)
        } else {
            try? FileManager.default.removeItem(at: fileURL(folder))
        }
    }

    /// `tmp = .<name>.<8 hex>.tmp` beside the file, then renamed over it.
    private static func writeAtomic(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)).tmp")
        try writeText(text, to: tmp)
        guard rename(tmp.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// `Path.write_text`: created 0666 less the umask, truncating.
    private static func writeText(_ text: String, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// What the editor shows: the paragraphs, and for each image the text read from it (null while it is
    /// still being read), and the revision.
    public static func document(_ folder: URL) -> JSONValue {
        let paragraphs = load(folder)
        var images: [(String, JSONValue)] = []
        for name in paragraphs.compactMap(\.image) {
            let entry = JSONValue.object([("text", .str(imageText(folder, name)))])
            if let k = images.firstIndex(where: { $0.0 == name }) { images[k].1 = entry } else { images.append((name, entry)) }
        }
        return .object([("paragraphs", .array(paragraphs.map(\.json))), ("images", .object(images)),
                        ("revision", .string(revision(folder)))])
    }

    /// Every file of the notes: what an undo snapshot of them holds (the document first, then the images
    /// by name).
    public static func files(_ folder: URL) -> [URL] {
        var out = [fileURL(folder)]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: imagesURL(folder).path)) ?? []
        let kept = names.filter { !$0.hasPrefix(".") && isFile(imagesURL(folder).appendingPathComponent($0)) }
        out += kept.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map { imagesURL(folder).appendingPathComponent($0) }
        return out
    }

    /// No notes any more: the document, the images and their text.
    public static func clear(_ folder: URL) throws {
        try locked(folder) {
            for f in files(folder) { try? FileManager.default.removeItem(at: f) }
        }
    }

    // MARK: - Images

    /// The file extension for image bytes, by their signature.
    static func kind(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        func starts(_ s: String) -> Bool { b.starts(with: Array(s.utf8)) }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if starts("GIF87a") || starts("GIF89a") { return "gif" }
        if b.count >= 12, starts("RIFF"), Array(b[8..<12]) == Array("WEBP".utf8) { return "webp" }
        if b.count >= 12, Array(b[4..<8]) == Array("ftyp".utf8),
           ["heic", "heix", "mif1", "msf1", "heim", "heis"].contains(String(decoding: b[8..<12], as: UTF8.self)) { return "heic" }
        return nil
    }

    /// Stores a pasted or dropped image; answers its name. Only images.
    public static func addImage(_ folder: URL, data: Data, maxBytes: Int = maxImageBytes) throws -> String {
        if data.count > maxBytes { throw MyNotesError.invalid("the image is too large (at most \(maxBytes / (1024 * 1024)) MB)") }
        guard let ext = kind(data) else { throw MyNotesError.invalid("not an image (PNG, JPEG, GIF, WebP or HEIC)") }
        let name = "img-\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12)).\(ext)"
        let url = imageURL(folder, name)
        try FileManager.default.createDirectory(at: imagesURL(folder), withIntermediateDirectories: true)
        let tmp = imagesURL(folder).appendingPathComponent(".\(name).tmp")
        try data.write(to: tmp)
        guard rename(tmp.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return name
    }

    public static func imagePath(_ folder: URL, _ name: String) throws -> URL {
        guard isImageName(name) else { throw MyNotesError.invalid(cut("not an image name: \(pyRepr(.string(name)))")) }
        let url = imageURL(folder, name)
        guard isFile(url) else { throw MyNotesError.notFound(name) }
        return url
    }

    /// By the extension of the name (`Path(name).suffix.lower()`).
    public static func contentType(_ name: String) -> String {
        let base = name.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? name
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return "application/octet-stream" }
        return contentTypes[String(base[dot...]).lowercased()] ?? "application/octet-stream"
    }

    /// The text read from an image; nil when it was not read yet.
    public static func imageText(_ folder: URL, _ name: String) -> String? {
        guard let data = try? Data(contentsOf: textURL(folder, name)), let text = String(data: data, encoding: .utf8) else { return nil }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")  // universal newlines
    }

    /// The image as a CGImage at most `maxReadPixels` wide and high, decoded scaled down (ImageIO): a huge
    /// image never reaches Vision whole.
    static func scaledImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw MyNotesError.invalid("not an image ImageIO can read")
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxReadPixels,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw MyNotesError.invalid("the image could not be decoded")
        }
        return image
    }

    /// The text in an image, by macOS Vision (German and English), line by line from the top. On this Mac;
    /// nothing is downloaded.
    public static func recognizeText(_ url: URL) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: try scaledImage(url), options: [:])
        do { try handler.perform([request]) } catch { throw MyNotesError.invalid("Vision could not read the image: \(error)") }
        var lines: [(Double, Double, String)] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let box = observation.boundingBox
            // Vision's origin is the bottom left: top to bottom, then left to right.
            lines.append((-Py.round(Double(box.origin.y + box.size.height), 2), Double(box.origin.x), candidate.string))
        }
        let sorted = Py.stableSorted(lines) { a, b in
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1 != b.1 { return a.1 < b.1 }
            return a.2.utf8.lexicographicallyPrecedes(b.2.utf8)
        }
        return sorted.map(\.2).joined(separator: "\n")
    }

    /// Reads the text in an image once and keeps it next to the image. A reading that fails counts as no
    /// text. An image deleted meanwhile leaves no text behind.
    @discardableResult
    public static func readImage(_ folder: URL, _ name: String, recognize: ((URL) throws -> String)? = nil) throws -> String {
        if let cached = imageText(folder, name) { return cached }
        let url = try imagePath(folder, name)
        reading.lock()
        defer { reading.unlock() }
        if let cached = imageText(folder, name) { return cached }
        var text: String
        do { text = Py.strip(try (recognize ?? recognizeText)(url)) } catch {
            log.warning("reading the text in \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            text = ""
        }
        if !FileManager.default.fileExists(atPath: url.path) { return text }  // deleted while it was read
        let target = textURL(folder, name)
        let tmp = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).tmp")
        if (try? writeText(text, to: tmp)) != nil { _ = rename(tmp.path, target.path) }  // a failure: the notes were cleared meanwhile
        if !FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: target) }
        return text
    }

    /// Reads every image of the notes not read yet (e.g. the app quit first).
    public static func readAll(_ folder: URL, recognize: ((URL) throws -> String)? = nil) {
        for p in load(folder) {
            guard let name = p.image, imageText(folder, name) == nil else { continue }
            _ = try? readImage(folder, name, recognize: recognize)
        }
    }

    /// A reading on its own thread; `wait` for it to end.
    public final class Reading: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        fileprivate init() {}
        fileprivate func finish() { done.signal() }
        /// Until it ended.
        public func wait() {
            done.wait()
            done.signal()
        }
        /// True when it ended within `seconds`.
        public func wait(seconds: Double) -> Bool {
            guard done.wait(timeout: .now() + seconds) == .success else { return false }
            done.signal()
            return true
        }
    }

    public static func readInBackground(_ folder: URL, _ name: String, recognize: ((URL) throws -> String)? = nil) -> Reading {
        let reading = Reading()
        let thread = Thread {
            do { try readImage(folder, name, recognize: recognize) } catch {
                log.error("reading the text in \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
            reading.finish()
        }
        thread.name = "my-notes-ocr"
        thread.start()
        return reading
    }

    /// An image and the text read from it: what deleting it removes.
    public static func imageFiles(_ folder: URL, _ name: String) throws -> [URL] {
        [try imagePath(folder, name), textURL(folder, name)]
    }

    /// Deletes an image: its paragraph, the file and its text. Answers the paragraph and the one before
    /// it (where an undo puts it back).
    public static func removeImage(_ folder: URL, _ name: String) throws -> (removed: Paragraph?, before: Paragraph?) {
        let url = try imagePath(folder, name)
        return try locked(folder) {
            let paragraphs = load(folder)
            let i = paragraphs.firstIndex { $0.image == name }
            let removed = i.map { paragraphs[$0] }
            let before = (i ?? 0) > 0 ? paragraphs[i! - 1] : nil
            try write(folder, paragraphs.filter { $0.image != name })
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: textURL(folder, name))
            return (removed, before)
        }
    }

    // MARK: - For the notes prompt, and for MCP

    private static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds)
        let hours = whole / 3600, minutes = whole % 3600 / 60, secs = whole % 60
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        return hours > 0 ? "\(hours):\(two(minutes)):\(two(secs))" : "\(two(minutes)):\(two(secs))"
    }

    private static let blockTag = try! PyRegex(#"<(\s*/?\s*my-notes)"#, ignoreCase: true)

    /// No text of the user's or read from an image can open or close the prompt's `<my-notes>` block.
    public static func neutralize(_ text: String) -> String {
        blockTag.sub(in: text) { "‹" + ($0.group(1) ?? "") }
    }

    /// The notes as text: one paragraph after the other, with the meeting time it was written at (on the
    /// transcript's clock); for an image, the text read from it. Empty when there are none.
    public static func promptText(_ folder: URL) -> String {
        var out: [String] = []
        for p in load(folder) {
            var text = Py.strip(p.text)
            if let name = p.image {
                let read = Py.strip(imageText(folder, name) ?? "")
                let image: String
                if read.isEmpty {
                    image = "[image without text]"
                } else {
                    let lines = splitLines(read).map(Py.strip).filter { !$0.isEmpty }
                    image = "[image; text on it, not written by the user: \(lines.joined(separator: " / "))]"
                }
                text = text.isEmpty ? image : "\(text) \(image)"
            }
            if text.isEmpty { continue }
            let lines = splitLines(text)
            let first = p.at.map { "[\(clock($0))] \(lines[0])" } ?? lines[0]
            out.append(([first] + lines.dropFirst().map { "  \($0)" }).joined(separator: "\n"))
        }
        return neutralize(out.joined(separator: "\n"))
    }

    /// `str.splitlines()`: at \n, \r, \r\n, \v, \f, \x1c-\x1e, \x85, U+2028 and U+2029; no empty tail.
    static func splitLines(_ s: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var previousWasCR = false
        for u in s.unicodeScalars {
            if previousWasCR, u == "\n" { previousWasCR = false; continue }
            previousWasCR = false
            switch u.value {
            case 0x0A, 0x0B, 0x0C, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029:
                lines.append(String(current)); current = String.UnicodeScalarView()
            case 0x0D:
                lines.append(String(current)); current = String.UnicodeScalarView(); previousWasCR = true
            default: current.append(u)
            }
        }
        if !current.isEmpty { lines.append(String(current)) }
        return lines
    }

    /// Changes with what the notes model would read; "" for no notes.
    public static func promptHash(_ text: String) -> String {
        guard !Py.strip(text).isEmpty else { return "" }
        return SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Before the meeting; cut and joined recordings

    /// Where the notes for a calendar event wait until it is recorded: the first 24 hex digits of the
    /// key's sha256, under the config folder's `prepared-notes`.
    public static func prepFolder(_ key: String, stores: StorePaths = .current()) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return stores.preparedNotes.appendingPathComponent(digest, isDirectory: true)
    }

    public static func hasPrepared(stores: StorePaths = .current()) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: stores.preparedNotes.path, isDirectory: &isDir), isDir.boolValue else { return false }
        return !((try? FileManager.default.contentsOfDirectory(atPath: stores.preparedNotes.path)) ?? []).isEmpty
    }

    /// `_move_images`: each image's file and text from `src` into `dst` (moved, or copied).
    private static func moveImages(_ src: URL, _ dst: URL, _ names: [String], copy: Bool = false) throws {
        let fm = FileManager.default
        for name in names {
            for f in [imageURL(src, name), textURL(src, name)] where fm.fileExists(atPath: f.path) {
                try fm.createDirectory(at: imagesURL(dst), withIntermediateDirectories: true)
                let target = imagesURL(dst).appendingPathComponent(f.lastPathComponent)
                try? fm.removeItem(at: target)
                if copy {
                    try fm.copyItem(at: f, to: target)
                } else if rename(f.path, target.path) != 0 {  // another volume: copy, then delete
                    try fm.copyItem(at: f, to: target)
                    try fm.removeItem(at: f)
                }
            }
        }
    }

    /// Moves the notes written before a meeting into its recording, in front of what was written during it.
    /// False when there were none.
    public static func adopt(_ src: URL, _ dst: URL) throws -> Bool {
        guard isDirectory(src) else { return false }
        return try both(src, dst) {
            let before = load(src)
            if hasContent(before) {
                try moveImages(src, dst, before.compactMap(\.image))
                try write(dst, before + load(dst))
            }
            try? FileManager.default.removeItem(at: src)
            return hasContent(before)
        }
    }

    /// Two recordings joined into `keep`: both notes, the second's times moved by `offset` (where it starts
    /// on the joined clock). The images are copied, so the other recording (going to the trash) stays whole.
    public static func join(_ first: URL, _ second: URL, keep: URL, offset: Double) throws {
        guard hasContent(load(first)) || hasContent(load(second)) else { return }
        try both(first, second) {
            let a = load(first)
            let b = load(second).map { p -> Paragraph in
                var q = p
                q.at = p.at.map { Py.round($0 + offset, 1) }
                return q
            }
            let otherIsSecond = keep.path == first.path
            let other = otherIsSecond ? second : first
            try moveImages(other, keep, (otherIsSecond ? b : a).compactMap(\.image), copy: true)
            // By time; what has none (written before or after) first, each part in its order.
            let untimed = (a + b).filter { $0.at == nil }
            let timed = Py.stableSorted((a + b).filter { $0.at != nil }) { $0.at! < $1.at! }
            try write(keep, untimed + timed)
        }
    }

    /// A recording cut `at` seconds: what was written from then on goes with the part after it, on its clock.
    public static func split(_ head: URL, _ tail: URL, at: Double) throws {
        func after(_ p: Paragraph) -> Bool { p.at.map { $0 >= at } ?? false }
        guard load(head).contains(where: after) else { return }
        try both(head, tail) {
            let paragraphs = load(head)
            let later = paragraphs.filter(after)
            try moveImages(head, tail, later.compactMap(\.image))
            let moved = later.map { p -> Paragraph in
                var q = p
                q.at = Py.round(p.at! - at, 1)
                return q
            }
            try write(tail, moved + load(tail))
            try write(head, paragraphs.filter { !after($0) })
        }
    }

    // MARK: - Small helpers

    private static func isFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// `text[:200]`, in characters (code points).
    private static func cut(_ s: String) -> String { String(String.UnicodeScalarView(s.unicodeScalars.prefix(200))) }

    /// Python's `repr` of a JSON value, for error messages.
    public static func pyRepr(_ v: JSONValue) -> String {
        switch v {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .double(let d): return Py.repr(d)
        case .string(let s): return pyStringRepr(s)
        case .array(let a): return "[" + a.map(pyRepr).joined(separator: ", ") + "]"
        case .object(let o): return "{" + o.map { "\(pyStringRepr($0.0)): \(pyRepr($0.1))" }.joined(separator: ", ") + "}"
        }
    }

    private static func pyStringRepr(_ s: String) -> String {
        let quote: Unicode.Scalar = s.contains("'") && !s.contains("\"") ? "\"" : "'"
        var out = String.UnicodeScalarView()
        out.append(quote)
        for u in s.unicodeScalars {
            switch u {
            case quote, "\\": out.append("\\"); out.append(u)
            case "\n": out.append(contentsOf: "\\n".unicodeScalars)
            case "\r": out.append(contentsOf: "\\r".unicodeScalars)
            case "\t": out.append(contentsOf: "\\t".unicodeScalars)
            default:
                if u.value < 0x20 || u.value == 0x7F {
                    out.append(contentsOf: String(format: "\\x%02x", u.value).unicodeScalars)
                } else {
                    out.append(u)
                }
            }
        }
        out.append(quote)
        return String(out)
    }
}
