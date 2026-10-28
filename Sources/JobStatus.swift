import Foundation

enum JobState: String, Codable, Hashable {
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

/// `lp` reports the new job as "<printer>-<job>" inside a localised sentence, so match on the printer name.
func parseSubmitted(_ text: String, printer: String) -> Int? {
    guard let r = text.range(of: printer + "-") else { return nil }
    return Int(text[r.upperBound...].prefix { $0.isNumber })
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

/// `ipptool -tv ... get-job-attributes` prints "job-impressions-completed (integer) = N": the pages the
/// printer reports as printed. CUPS leaves "processing-to-stop-point" on successful jobs too, so it
/// cannot be used to tell a printed job from a refused one.
func parseImpressions(_ text: String) -> Int? {
    guard let r = text.range(of: "job-impressions-completed (integer) = ") else { return nil }
    return Int(text[r.upperBound...].prefix { $0.isNumber })
}

struct QueueSnapshot {
    var pending: [Int: String] = [:]   // not-completed jobs
    var history: [Int: String] = [:]   // all jobs, including completed and canceled
    var impressions: [Int: Int] = [:]  // pages printed, for jobs that have left the queue

    func state(of job: Int) -> (JobState, String?) {
        if let text = pending[job] {
            return (text.contains("job-printing") ? .printing : .queued, nil)
        }
        let text = history[job] ?? ""
        if text.contains("canceled-by-user") { return (.canceled, nil) }
        if let pages = impressions[job] {
            return pages > 0 ? (.done, nil) : (.failed, "Yazıcı belgeyi basmadı")
        }
        if text.contains("completed-successfully") { return (.done, nil) }
        if text.contains("processing-to-stop-point") || text.contains("abort") || text.contains("error") || text.contains("stopped") {
            return (.failed, text.trimmingCharacters(in: .whitespaces))
        }
        if text.contains("cancel") { return (.canceled, nil) }
        // Left the queue without a recorded reason (history purged): the printer accepted it.
        return (.done, history[job] == nil ? "Kuyruktan çıktı, sonuç doğrulanamadı" : nil)
    }
}
