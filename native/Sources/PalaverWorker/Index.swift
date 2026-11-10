// `palaver-worker index [folder…]` (cli.py `_cmd_index`, semantic.py `index_stale`): the search-by-meaning index of
// the meetings without a current one (or of the folders named), the e5 model loaded once and only when there is
// something to index; downloaded first (`download`: PalaverCloud's HubDownloader, the pinned revision) when it is not on
// this Mac. It runs at background QoS and stops between meetings once a recording or a transcription runs, or free
// memory falls under `SearchIndex.INDEX_MEMORY_GB` (the daemon's rule for starting it).
import Foundation
import PalaverCloud
import PalaverCore
import PalaverDomain

public enum Index {
    /// Index the stale meetings (`only` these folders, live ones left out); prints what it did. 1 when the model
    /// could not be had.
    public static func run(outputDir: URL, only folders: [URL]? = nil, stores: StorePaths, download: @escaping () throws -> Void,
                           modelFolder: @escaping () -> URL?, encoder makeEncoder: @escaping (URL) throws -> MeaningEncoder,
                           shouldStop: @escaping () -> Bool, say: @escaping (String) -> Void = Pipeline.printLine) async -> Int32 {
        guard SearchIndex.enabled(stores: stores) else {
            say("Search by meaning is switched off in the settings.")
            return 0
        }
        let only = folders.map { $0.filter { !WorkerPids.liveRunning($0) }.map { RecordingPaths($0) } }
        let factory: () throws -> MeaningEncoder? = {
            if modelFolder() == nil {
                do {
                    try download()
                } catch {
                    throw WorkerError("the search model could not be downloaded: \(error)")
                }
                guard modelFolder() != nil else { throw WorkerError("the search model could not be downloaded") }
            }
            guard let folder = modelFolder() else { return nil }
            return try makeEncoder(folder)
        }
        let result: Result<Int, Error> = await background {
            Result { try SearchIndex.indexStale(outputDir: outputDir, encoder: factory, shouldStop: shouldStop, only: only) }
        }
        switch result {
        case .success(let done):
            say("Indexed \(done) meeting\(done != 1 ? "s" : "") for search by meaning.")
            return 0
        case .failure(let error):
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 1
        }
    }

    /// The e5 model from Hugging Face into the cache (embeddings.py `model_folder(download=True)`): its pinned revision
    /// and three files; `token()` is asked only now.
    public static func downloadE5(hub: HubDownloader, token: () -> String?) throws {
        try hub.fetchPinned(E5Encoder.model, token: token())
    }

    /// `body` on a thread of background QoS, awaited.
    static func background<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            let thread = Thread { c.resume(returning: body()) }
            thread.qualityOfService = .background
            thread.start()
        }
    }

    /// Whether the index should pause: the app records or transcribes (daemon.json; one that can't be read counts as
    /// busy), or free memory is under INDEX_MEMORY_GB.
    public static func shouldStop(stores: StorePaths, freeGB: @escaping () -> Double) -> () -> Bool {
        {
            let file = stores.daemonJson
            if FileManager.default.fileExists(atPath: file.path) {
                guard let state = PythonJSON.read(file), case .object = state else { return true }
                if state["state"]?.stringValue == "recording" || state["transcribing"]?.truthy == true { return true }
            }
            return freeGB() < SearchIndex.INDEX_MEMORY_GB
        }
    }
}
