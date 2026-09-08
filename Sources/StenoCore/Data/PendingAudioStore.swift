import Foundation

/// Durable spool for segment audio that is waiting to be transcribed.
///
/// The file on disk *is* the queue. Audio is written the moment a segment
/// closes and removed only once its transcript has been stored, so quitting the
/// app, losing power, or being offline for hours cannot drop a recording.
/// Anything still present at launch is work that never finished, and is
/// requeued in capture order.
public actor PendingAudioStore {
    /// Everything needed to rebuild a transcription job without consulting the
    /// database, so resuming after a relaunch stays a directory listing.
    public struct Entry: Codable, Sendable {
        public let jobID: String
        public let segment: TranscriptSegment
        public let sampleRate: Double

        public init(jobID: String, segment: TranscriptSegment, sampleRate: Double) {
            self.jobID = jobID
            self.segment = segment
            self.sampleRate = sampleRate
        }
    }

    public struct Stats: Sendable {
        public let pendingCount: Int
        public let pendingBytes: Int64
        public let retainedBytes: Int64
    }

    private let directory: URL
    private let retainedDirectory: URL
    private let fileManager = FileManager.default

    /// Samples are stored as 16-bit PCM rather than the captured `Float`s: it
    /// halves the spool on disk, and it is the same depth the WAV upload already
    /// converts to, so nothing that reaches a provider loses precision.
    private static let sampleScale = Float(Int16.max)

    public init(directory: URL) throws {
        self.directory = directory
        self.retainedDirectory = directory.appendingPathComponent("Transcribed", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func metadataURL(_ jobID: String) -> URL {
        directory.appendingPathComponent("\(jobID).json")
    }

    private func audioURL(_ jobID: String) -> URL {
        directory.appendingPathComponent("\(jobID).pcm16")
    }

    /// Writes the audio first and the metadata second: metadata is what
    /// `pendingEntries()` lists, so a crash mid-save leaves an orphan audio file
    /// rather than an entry pointing at audio that was never written.
    public func save(entry: Entry, samples: [Float]) throws {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let scaled = Int16(max(-1, min(1, sample)) * Self.sampleScale)
            withUnsafeBytes(of: scaled.littleEndian) { pcm.append(contentsOf: $0) }
        }
        try pcm.write(to: audioURL(entry.jobID), options: .atomic)
        try JSONEncoder().encode(entry).write(to: metadataURL(entry.jobID), options: .atomic)
    }

    public func samples(for jobID: String) throws -> [Float] {
        let data = try Data(contentsOf: audioURL(jobID))
        return data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / Self.sampleScale }
        }
    }

    /// Unfinished work, oldest first, so a backlog is transcribed in the order
    /// it was spoken.
    public func pendingEntries() -> [Entry] {
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Entry.self, from: Data(contentsOf: $0)) }
            .filter { fileManager.fileExists(atPath: audioURL($0.jobID).path) }
            .sorted { $0.segment.startedAtMs < $1.segment.startedAtMs }
    }

    /// Called once a transcript is safely stored. Dropping the audio is what
    /// marks the job done, so this must not run before the transcript is
    /// persisted. When `keepAudio` is set the segment is converted to a playable
    /// WAV and moved aside instead of being deleted.
    public func finish(jobID: String, sampleRate: Double, keepAudio: Bool) {
        if keepAudio, let samples = try? samples(for: jobID) {
            let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
            let wav = OpenAICompatibleSTTProvider.makeWAVData(
                pcmFloat32LittleEndian: pcm,
                sampleRate: sampleRate
            )
            try? fileManager.createDirectory(at: retainedDirectory, withIntermediateDirectories: true)
            try? wav.write(to: retainedDirectory.appendingPathComponent("\(jobID).wav"), options: .atomic)
        }
        discard(jobID: jobID)
    }

    /// Removes the spool files without retaining anything.
    public func discard(jobID: String) {
        try? fileManager.removeItem(at: audioURL(jobID))
        try? fileManager.removeItem(at: metadataURL(jobID))
    }

    public func stats() -> Stats {
        func bytes(of urls: [URL]) -> Int64 {
            urls.reduce(into: Int64(0)) { total, url in
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        let pending = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        let retained = (try? fileManager.contentsOfDirectory(
            at: retainedDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return Stats(
            pendingCount: pending.filter { $0.pathExtension == "json" }.count,
            pendingBytes: bytes(of: pending),
            retainedBytes: bytes(of: retained)
        )
    }

    /// Deletes every spooled and retained file. Used by "delete all transcripts",
    /// so purging text does not leave the audio it came from behind.
    public func removeAll() {
        for url in (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? fileManager.removeItem(at: url)
        }
    }
}
