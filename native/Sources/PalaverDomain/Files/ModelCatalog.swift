// The models Palaver may download and how much of each is on this Mac (palaver/onboarding.py:65-117 `Model`, `MODELS`,
// `RETIRED`, `NOTES_MODELS`; :915-1056 `cached_bytes`, `complete`, `speech_files_here`, `model_here`,
// `download_progress`, `downloads_running`, `repo_for`). Nothing here downloads or deletes.
import Foundation
import PalaverCore

/// A model the setup assistant may download (onboarding.Model).
public struct ModelInfo: Sendable, Equatable {
    public let id: String
    public let label: String
    public let purpose: String
    public let repo: String
    /// A file of the repo that is there once it is downloaded.
    public let probe: String
    public let diskGB: Double
    /// What it uses, said plainly.
    public let memory: String
    /// A release carries a copy (model_store).
    public let hosted: Bool
    /// A folder of Application Support/palaver/models that holds it (or an old copy of it); "" for none.
    public let localFolder: String
    /// Retired, but never dropped at start: Settings → Storage offers to delete it.
    public let manual: Bool
    /// config.toml's transcriber that still uses it: kept while chosen; "" for none.
    public let transcriber: String

    init(_ id: String, _ label: String, _ purpose: String, _ repo: String, _ probe: String, _ diskGB: Double,
         _ memory: String, hosted: Bool = false, localFolder: String = "", manual: Bool = false, transcriber: String = "") {
        self.id = id
        self.label = label
        self.purpose = purpose
        self.repo = repo
        self.probe = probe
        self.diskGB = diskGB
        self.memory = memory
        self.hosted = hosted
        self.localFolder = localFolder
        self.manual = manual
        self.transcriber = transcriber
    }
}

public enum ModelCatalog {
    public static let GEMMA = "mlx-community/gemma-4-12B-it-OptiQ-4bit"
    public static let QWEN = "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"

    /// The speech models are one download: palaver-engine's own (Parakeet v3 and the diarizer, CoreML), in
    /// models/fluidaudio.
    public static let SPEECH_FOLDER = "fluidaudio"
    public static let SPEECH_FILES = [
        "parakeet-tdt-0.6b-v3/Preprocessor.mlmodelc", "parakeet-tdt-0.6b-v3/Encoder.mlmodelc",
        "parakeet-tdt-0.6b-v3/Decoder.mlmodelc", "parakeet-tdt-0.6b-v3/JointDecisionv3.mlmodelc",
        "parakeet-tdt-0.6b-v3/parakeet_v3_vocab.json",
        "speaker-diarization/Segmentation.mlmodelc", "speaker-diarization/Embedding.mlmodelc",
        "speaker-diarization/FBank.mlmodelc", "speaker-diarization/PldaRho.mlmodelc",
        "speaker-diarization/plda-parameters.json",
    ]

    /// `MODELS`, in Python's order.
    public static let models: [ModelInfo] = [
        ModelInfo("speech", "Speech models", "transcription and telling the speakers apart", "fluidaudio",
                  "speaker-diarization/plda-parameters.json", 0.5, "under 1 GB while transcribing",
                  localFolder: SPEECH_FOLDER),
        ModelInfo("gemma", "Gemma 4 12B", "notes and projects", GEMMA, "config.json", 8.3,
                  "about 10 GB of memory while writing, up to 12 GB"),
        ModelInfo("e5", "multilingual-e5-small", "search by meaning", "intfloat/multilingual-e5-small", "config.json", 0.47,
                  "little memory, in the background"),
    ]

    /// Local notes model (repo) → its download.
    public static let notesModels = PyDict<String>([(GEMMA, "gemma")])

    /// `RETIRED`: no longer offered, listed so Settings → Storage can delete a copy still here.
    public static let retired: [ModelInfo] = [
        ModelInfo("qwen", "Qwen3 30B A3B", "notes and projects (no longer offered)", QWEN, "config.json", 16.0,
                  "18–22 GB of memory while writing"),
        ModelInfo("parakeet", "Parakeet (MLX)", "transcription (replaced by the speech models)",
                  "mlx-community/parakeet-tdt-0.6b-v3", "config.json", 2.3, "about 2.5 GB of memory while transcribing",
                  manual: true),
        ModelInfo("pyannote", "pyannote", "telling the speakers apart (replaced by the speech models)",
                  "pyannote/speaker-diarization-community-1", "config.yaml", 0.03, "about 1 GB of memory while it runs",
                  localFolder: "pyannote-community-1", manual: true),
        // The default transcriber until October 2026 (#8: 1.5 GB nobody saw); still there for config.toml's
        // transcriber = "mlx-whisper".
        ModelInfo("whisper", "Whisper (MLX)", "transcription (replaced by the speech models)",
                  "mlx-community/whisper-large-v3-turbo", "config.json", 1.5, "used only with transcriber = mlx-whisper",
                  manual: true, transcriber: "mlx-whisper"),
    ]

    /// `MODELS.get(id) or RETIRED.get(id)`.
    public static func model(_ id: String) -> ModelInfo? {
        models.first { Py.same($0.id, id) } ?? retired.first { Py.same($0.id, id) }
    }

    public static func isRetired(_ id: String) -> Bool { retired.contains { Py.same($0.id, id) } }

    /// The model's repo: config.toml no longer overrides it; "speech" is not a Hugging Face repo.
    public static func repoFor(_ model: ModelInfo) -> String { model.repo }

    // MARK: - The Hugging Face cache

    /// `_cache_dir(repo)`: `<hub cache>/models--<repo with "/" as "--">`.
    public static func cacheDir(_ repo: String, stores: StorePaths = .current()) -> URL {
        stores.hubCache.appendingPathComponent("models--" + replace(repo, "/", "--"), isDirectory: true)
    }

    /// What of `repo` is in the Hugging Face cache, partial files included: the files of `blobs` (links followed);
    /// 0 when the folder can't be read.
    public static func cachedBytes(_ repo: String, stores: StorePaths = .current()) -> Int {
        let blobs = cacheDir(repo, stores: stores).path + "/blobs"
        guard let names = try? Undo.listdir(blobs) else { return 0 }
        var total = 0
        for name in names {
            guard let st = Undo.statOf(blobs + "/" + name), isRegular(st) else { continue }
            total += Int(st.st_size)
        }
        return total
    }

    /// Whether `repo` is fully downloaded: no partial blob, and a snapshot (huggingface_hub's cache scan) with a file
    /// named `probe` whose every file is there and not empty; for a language model also the weights it loads
    /// (`weightsHere`, the rule palaver-lm and the downloader use: a download stopped between two files leaves no
    /// partial blob but misses a shard), so setup and the notes agree on what is downloaded.
    public static func complete(_ repo: String, probe: String = "config.json", stores: StorePaths = .current()) -> Bool {
        let folder = Undo.pyPath(cacheDir(repo, stores: stores).path)
        let blobs = folder + "/blobs"
        guard Undo.isDir(blobs), let names = try? Undo.listdir(blobs) else { return false }
        if names.contains(where: { $0.unicodeScalars.reversed().starts(with: ".incomplete".unicodeScalars.reversed()) }) {
            return false
        }
        guard let snaps = try? Undo.listdir(folder + "/snapshots") else { return false }
        for snap in snaps {  // a file whose blob is gone: not complete
            var broken = false
            walk(folder + "/snapshots/" + snap) { path, l in
                if l.st_mode & S_IFMT == S_IFLNK && Undo.statOf(path) == nil { broken = true }
            }
            if broken { return false }
        }
        guard let revisions = scanRepo(folder), repoId(folder).map({ Py.same($0, repo) }) == true else { return false }
        let languageModel = isLanguageModel(repo)
        return revisions.contains { rev in
            rev.files.contains { Py.same($0.name, probe) } && rev.files.allSatisfy { Undo.exists($0.blob) && $0.size > 0 }
                && (!languageModel || weightsHere(rev.snap))
        }
    }

    /// A model palaver-lm loads (a notes model, offered or retired).
    public static func isLanguageModel(_ repo: String) -> Bool {
        notesModels[repo] != nil || Py.same(repo, QWEN)
    }

    /// Whether the weights a model loads are in the snapshot folder `snap`, by the rule mlx_lm and mlx-swift-lm choose
    /// them with: every shard `model.safetensors.index.json` names; or, when some of those are not here, every
    /// `model*.safetensors` shard it names (rc6's Gemma index also names `optiq_vision.safetensors`, its vision
    /// sidecar, which Palaver never downloads: the model loads without it); without an index, any `model*.safetensors`.
    /// A download cut short misses a shard. (Python's `snapshot_complete` asks for every shard the index names.) One
    /// rule for setup (`complete`), the downloader and palaver-lm (`HFCache.weightsHere` forwards here).
    public static func weightsHere(_ snap: String) -> Bool {
        let isFile = { (path: String) in Undo.statOf(path).map(isRegular) ?? false }
        let index = snap + "/model.safetensors.index.json"
        guard Undo.statOf(index) != nil else {
            return ((try? Undo.listdir(snap)) ?? []).contains { isWeights($0) && isFile(snap + "/" + $0) }
        }
        guard let json = PythonJSON.read(URL(fileURLWithPath: index)), case .object(let map)? = json["weight_map"] else {
            return false
        }
        let shards = map.compactMap { $0.1.stringValue }  // the same shard again is checked again: harmless
        if !shards.isEmpty && shards.allSatisfy({ isFile(snap + "/" + $0) }) { return true }
        let named = shards.filter(isWeights)
        return !named.isEmpty && named.allSatisfy { isFile(snap + "/" + $0) }
    }

    /// fnmatch's `model*.safetensors` (`*` matches anything, "/" included).
    static func isWeights(_ name: String) -> Bool {
        let s = name.unicodeScalars
        return s.count >= 17 && s.starts(with: "model".unicodeScalars) && s.reversed().starts(with: ".safetensors".unicodeScalars.reversed())
    }

    /// The repo id huggingface_hub reads from a cache folder's name ("models--a--b" → "a/b"); nil when it is no model's.
    private static func repoId(_ folder: String) -> String? {
        let name = Array(Undo.basename(folder).unicodeScalars)
        guard let i = name.indices.first(where: { $0 + 1 < name.count && name[$0] == "-" && name[$0 + 1] == "-" }),
              String(String.UnicodeScalarView(name[..<i])) == "models" else { return nil }
        return replace(String(String.UnicodeScalarView(name[(i + 2)...])), "--", "/")
    }

    private struct CachedFile {
        let name: String
        let blob: String
        let size: Int
    }

    /// `_scan_cached_repo` of huggingface_hub 2.3: each revision's files; nil where it raises CorruptedCacheException
    /// (or reading a ref fails).
    private static func scanRepo(_ repo: String) -> [(snap: String, files: [CachedFile])]? {
        guard Undo.isDir(repo), Undo.isDir(repo + "/snapshots") else { return nil }
        let ignore = [".DS_Store", "Thumbs.db", "desktop.ini"]
        var refs: [String] = []  // the commits refs/ names
        let refsPath = repo + "/refs"
        if let st = Undo.statOf(refsPath) {
            if isRegular(st) { return nil }
            var failed = false
            walk(refsPath) { path, _ in
                if Undo.isDir(path) || ignore.contains(where: { Py.same($0, Undo.basename(path)) }) { return }
                guard let data = FileManager.default.contents(atPath: path), let text = String(validatingUTF8Data: data) else {
                    failed = true
                    return
                }
                // open() in text mode: universal newlines.
                refs.append(replace(replace(text, "\r\n", "\n"), "\r", "\n"))
            }
            if failed { return nil }
        }
        guard let snaps = try? Undo.listdir(repo + "/snapshots") else { return nil }
        var revisions: [(snap: String, files: [CachedFile])] = []
        for snap in snaps where !ignore.contains(where: { Py.same($0, snap) }) {
            let revision = repo + "/snapshots/" + snap
            if let st = Undo.statOf(revision), isRegular(st) { return nil }
            var files: [CachedFile] = [], corrupt = false
            walk(revision) { path, l in
                if Undo.isDir(path) { return }
                var blob = path
                if l.st_mode & S_IFMT == S_IFLNK, let target = readlink(path) {
                    blob = normpath(target.hasPrefix("/") ? target : Undo.dirname(path) + "/" + target)
                }
                guard let st = Undo.statOf(blob) else { corrupt = true; return }
                files.append(CachedFile(name: Undo.basename(path), blob: blob, size: Int(st.st_size)))
            }
            // An empty revision is dated by its own stat: a broken link there raises (not as a corrupt cache).
            if corrupt || (files.isEmpty && Undo.statOf(revision) == nil) { return nil }
            revisions.append((revision, files))
            refs.removeAll { Py.same($0, snap) }
        }
        return refs.isEmpty ? revisions : nil  // a ref to a commit that is not here
    }

    // MARK: - On this Mac

    /// Every file of the speech models is in `models/fluidaudio`: the cheap check (`speech_files_here`).
    public static func speechFilesHere(stores: StorePaths = .current()) -> Bool {
        let root = stores.modelsDir.appendingPathComponent(SPEECH_FOLDER, isDirectory: true).path
        return SPEECH_FILES.allSatisfy { Undo.exists(root + "/" + $0) }
    }

    /// Whether every file of `model` is on this Mac (`model_here`). The speech models ask `speechHere`: Python's
    /// `speech_here` lets the engine have the last word, which the domain can't start; the caller passes it (or
    /// `speechFilesHere`). No model is hosted (model_store.HOSTED is empty), so the rest is the cache's.
    public static func modelHere(_ model: ModelInfo, repo: String, speechHere: () -> Bool,
                                 stores: StorePaths = .current()) -> Bool {
        if Py.same(model.id, "speech") { return speechHere() }
        return complete(repo, probe: model.probe, stores: stores)
    }

    /// Bytes of `repo` here so far. model_store.HOSTED is empty, so this is always the cache's.
    public static func downloadProgress(_ repo: String, stores: StorePaths = .current()) -> Int {
        cachedBytes(repo, stores: stores)
    }

    /// Whether the window's server downloads models now: its marker names a live pid (`kill(pid, 0)`; a process of
    /// another user counts).
    public static func downloadsRunning(_ marker: URL) -> Bool {
        guard let data = FileManager.default.contents(atPath: marker.path), let text = String(validatingUTF8Data: data),
              let pid = pyInt(Py.strip(text)), let p = pid_t(exactly: pid) else { return false }
        if kill(p, 0) == 0 { return true }
        return errno == EPERM
    }

    // MARK: - Helpers

    /// Python's `int(text)` of a stripped string: a sign, decimal digits (any script), single "_" between digits.
    public static func pyInt(_ text: String) -> Int? {
        var scalars = Substring(text).unicodeScalars[...]
        var negative = false
        if let first = scalars.first, first == "+" || first == "-" {
            negative = first == "-"
            scalars = scalars.dropFirst()
        }
        var value = 0, digits = 0, lastUnderscore = false
        for u in scalars {
            if u == "_" {
                guard digits > 0, !lastUnderscore else { return nil }
                lastUnderscore = true
                continue
            }
            guard Py.isDecimal(u), let d = u.properties.numericValue.flatMap({ Int(exactly: $0) }) else { return nil }
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let (s, o2) = m.addingReportingOverflow(d)
            guard !o1, !o2 else { return nil }
            value = s
            digits += 1
            lastUnderscore = false
        }
        guard digits > 0, !lastUnderscore else { return nil }
        return negative ? -value : value
    }

    /// `str.replace` by code points.
    static func replace(_ s: String, _ old: String, _ new: String) -> String {
        let src = Array(s.unicodeScalars), pat = Array(old.unicodeScalars)
        guard !pat.isEmpty else { return s }
        var out = String.UnicodeScalarView(), i = 0
        while i < src.count {
            if i + pat.count <= src.count, Array(src[i..<i + pat.count]) == pat {
                out.append(contentsOf: new.unicodeScalars)
                i += pat.count
            } else {
                out.append(src[i])
                i += 1
            }
        }
        return String(out)
    }

    static func isRegular(_ st: stat) -> Bool { st.st_mode & S_IFMT == S_IFREG }

    /// `path.glob("**/*")` / `rglob("*")` (Python 3.13): every entry below `dir` with its `lstat`; symlinked folders are
    /// listed but not entered; folders that can't be read are skipped.
    static func walk(_ dir: String, _ visit: (String, stat) -> Void) {
        for name in (try? Undo.listdir(dir)) ?? [] {
            let path = dir + "/" + name
            var l = stat()
            guard lstat(path, &l) == 0 else { continue }
            visit(path, l)
            if l.st_mode & S_IFMT == S_IFDIR { walk(path, visit) }
        }
    }

    /// `os.readlink`.
    static func readlink(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = Darwin.readlink(path, &buffer, buffer.count - 1)
        guard n >= 0 else { return nil }
        return String(decoding: buffer[..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// `os.path.normpath` of an absolute path: no empty or "." parts, ".." takes the part before it.
    static func normpath(_ path: String) -> String {
        var parts: [Substring.UnicodeScalarView] = []
        let scalars = path.unicodeScalars
        for part in scalars.split(separator: "/", omittingEmptySubsequences: true) {
            let p = String(String.UnicodeScalarView(part))
            if p == "." { continue }
            if p == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(Substring.UnicodeScalarView(part))
        }
        let lead = scalars.starts(with: "//".unicodeScalars) && !scalars.starts(with: "///".unicodeScalars) ? "//" : "/"
        return lead + parts.map { String(String.UnicodeScalarView($0)) }.joined(separator: "/")
    }
}

extension String {
    /// The text of UTF-8 bytes, a byte order mark kept; nil when they are not UTF-8 (Python's strict decoding).
    init?(validatingUTF8Data data: Data) {
        let s = String(decoding: data, as: UTF8.self)
        guard s.utf8.elementsEqual(data) else { return nil }
        self = s
    }
}
