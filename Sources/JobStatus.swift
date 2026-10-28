import Foundation

enum JobState: Hashable {
    case ready, sending, queued, printing, done, canceled, failed

    var label: String {
        switch self {
        case .ready: return "Hazır"
        case .sending: return "Gönderiliyor"
        case .queued: return "Sırada"
        case .printing: return "Yazdırılıyor"
        case .done: return "Yazdırıldı"
        case .canceled: return "İptal"
        case .failed: return "Hata"
        }
    }

    /// Still on its way to the printer.
    var isActive: Bool { self == .sending || self == .queued || self == .printing }
}

/// Job number from a CUPS job name such as "HP_Smart_Tank_580_590_series__4A24F4_-472".
func jobID(fromName name: String) -> Int? {
    guard let dash = name.lastIndex(of: "-") else { return nil }
    return Int(name[name.index(after: dash)...])
}

/// `lp` prints "request id is <printer>-<job> (1 file(s))".
func parseSubmitted(_ text: String) -> Int? {
    guard let part = text.components(separatedBy: "request id is ").dropFirst().first else { return nil }
    return jobID(fromName: String(part.prefix { !$0.isWhitespace }))
}

/// `lpstat -o` / `lpstat -l -o` output → lowercased alert and status text per job number.
func parseJobList(_ text: String) -> [Int: String] {
    var jobs: [Int: String] = [:]
    var current: Int?
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.first == " " || line.first == "\t" {
            if let c = current { jobs[c, default: ""] += " " + line.lowercased() }
        } else if let first = line.split(separator: " ").first, let id = jobID(fromName: String(first)) {
            current = id
            jobs[id, default: ""] = ""
        } else {
            current = nil
        }
    }
    return jobs
}

/// `lpstat -p` prints "printer <name> now printing <name>-<job>." while a job is on paper.
func parsePrinting(_ text: String) -> Set<Int> {
    var ids = Set<Int>()
    for part in text.components(separatedBy: "now printing ").dropFirst() {
        let token = part.prefix { !$0.isWhitespace }.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if let id = jobID(fromName: token) { ids.insert(id) }
    }
    return ids
}

struct QueueSnapshot {
    var pending: [Int: String] = [:]   // not-completed jobs
    var history: [Int: String] = [:]   // all jobs, including completed and canceled
    var printing = Set<Int>()

    func state(of job: Int) -> (JobState, String?) {
        if let text = pending[job] {
            return (printing.contains(job) || text.contains("job-printing") ? .printing : .queued, nil)
        }
        let text = history[job] ?? ""
        if text.contains("completed-successfully") { return (.done, nil) }
        if text.contains("cancel") || text.contains("processing-to-stop-point") { return (.canceled, nil) }
        if text.contains("abort") || text.contains("error") || text.contains("stopped") {
            return (.failed, text.trimmingCharacters(in: .whitespaces))
        }
        // Left the queue without a recorded reason (history purged): the printer accepted it.
        return (.done, history[job] == nil ? "Kuyruktan çıktı, sonuç doğrulanamadı" : nil)
    }
}
