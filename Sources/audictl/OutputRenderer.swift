import ArgumentParser
import AudictlCore
import Foundation

/// Runs a command body and renders its result per the global output flags.
/// JSON mode puts both success and error envelopes on stdout so agents only
/// ever capture one stream; human mode keeps errors on stderr.
func rendered<T: Encodable>(_ globals: GlobalOptions,
                            human: (T, Bool?) -> String,
                            body: () throws -> (data: T, changed: Bool?)) throws {
    do {
        let (data, changed) = try body()
        if globals.json {
            print(JSONRendering.encode(SuccessEnvelope(data: data, changed: changed)))
        } else if !globals.quiet {
            let text = human(data, changed)
            if !text.isEmpty { print(text) }
        }
    } catch let error as ExitCode {
        throw error
    } catch {
        let normalized = normalize(error)
        if globals.json {
            print(JSONRendering.encode(ErrorEnvelope(normalized)))
        } else if !globals.quiet {
            FileHandle.standardError.write(Data("audictl: \(normalized.message)\n".utf8))
        }
        throw ExitCode(normalized.exitCode)
    }
}

private func normalize(_ error: Error) -> AudictlError {
    if let e = error as? AudictlError { return e }
    if let e = error as? HALError { return .hal(e) }
    return .internalError(String(describing: error))
}

// MARK: - Human rendering helpers

func formatRate(_ hz: Double) -> String {
    hz == hz.rounded() && hz.truncatingRemainder(dividingBy: 100) == 0
        ? String(format: "%.1f kHz", hz / 1000)
        : String(format: "%g Hz", hz)
}

/// Aligned table lines; index 0 is the header, then one line per row.
func formatTableLines(_ rows: [[String]], header: [String]) -> [String] {
    let all = [header] + rows
    var widths = [Int](repeating: 0, count: header.count)
    for row in all {
        for (i, cell) in row.enumerated() where i < widths.count {
            widths[i] = max(widths[i], cell.count)
        }
    }
    return all.map { row in
        row.enumerated()
            .map { i, cell in cell.padding(toLength: widths[i], withPad: " ", startingAt: 0) }
            .joined(separator: "  ")
            .trimmingCharacters(in: .whitespaces)
    }
}

func formatTable(_ rows: [[String]], header: [String]) -> String {
    formatTableLines(rows, header: header).joined(separator: "\n")
}

func subDeviceLine(_ sub: SubDeviceDTO, clockUID: String?, indent: String) -> String {
    let clock = sub.uid == clockUID ? " [clock]" : ""
    let drift = sub.driftCompensation ? " drift" : ""
    return "\(indent)└ \(sub.name ?? sub.uid)\(clock)\(drift)"
}

func deviceRow(_ d: DeviceInfoDTO) -> [String] {
    var flags: [String] = []
    if d.isDefaultInput { flags.append("default-in") }
    if d.isDefaultOutput { flags.append("default-out") }
    if d.isDefaultSystem { flags.append("system") }
    if d.isMultiOutput {
        flags.append("multi")
    } else if d.isAggregate {
        flags.append("aggregate")
    }
    return [
        String(d.id),
        d.name,
        String(d.input.channels),
        String(d.output.channels),
        d.sampleRate.map { formatRate($0) } ?? "-",
        d.transport,
        flags.joined(separator: ","),
    ]
}

let deviceHeader = ["ID", "NAME", "IN", "OUT", "RATE", "TRANSPORT", "FLAGS"]

func describeDevice(_ d: DeviceInfoDTO) -> String {
    var lines: [String] = []
    lines.append("\(d.name) (id \(d.id))")
    lines.append("  uid:          \(d.uid)")
    if let m = d.manufacturer { lines.append("  manufacturer: \(m)") }
    lines.append("  transport:    \(d.transport)")
    lines.append("  input:        \(d.input.channels) ch"
        + (d.input.volume.map { String(format: ", volume %.0f%%", $0 * 100) } ?? "")
        + (d.input.muted.map { $0 ? ", muted" : "" } ?? ""))
    lines.append("  output:       \(d.output.channels) ch"
        + (d.output.volume.map { String(format: ", volume %.0f%%", $0 * 100) } ?? "")
        + (d.output.muted.map { $0 ? ", muted" : "" } ?? ""))
    if let rate = d.sampleRate { lines.append("  sample rate:  \(formatRate(rate))") }
    if let rates = d.availableSampleRates, !rates.isEmpty {
        lines.append("  available:    " + rates.map { formatRate($0) }.joined(separator: ", "))
    }
    var flags: [String] = []
    if d.isDefaultInput { flags.append("default input") }
    if d.isDefaultOutput { flags.append("default output") }
    if d.isDefaultSystem { flags.append("default system") }
    if d.isMultiOutput { flags.append("multi-output") } else if d.isAggregate { flags.append("aggregate") }
    if !d.isAlive { flags.append("not alive") }
    if d.isRunning { flags.append("running") }
    if !flags.isEmpty { lines.append("  flags:        " + flags.joined(separator: ", ")) }
    if let subs = d.subDevices, !subs.isEmpty {
        lines.append("  contains:")
        for sub in subs {
            lines.append(subDeviceLine(sub, clockUID: d.clockDeviceUID, indent: "    "))
        }
    }
    return lines.joined(separator: "\n")
}

func describeAggregate(_ a: AggregateDTO) -> String {
    var lines: [String] = []
    let kind = a.isMultiOutput ? "multi-output" : "aggregate"
    lines.append("\(a.name) (id \(a.id), \(kind)\(a.isPrivate ? ", private" : ""))")
    lines.append("  uid: \(a.uid)")
    for sub in a.subDevices {
        let clock = sub.uid == a.clockDeviceUID ? " [clock]" : ""
        let drift = sub.driftCompensation ? " drift" : ""
        lines.append("  - \(sub.name ?? sub.uid)\(clock)\(drift)  (\(sub.uid))")
    }
    return lines.joined(separator: "\n")
}

// MARK: - Value parsing

func parseVolumeValue(_ raw: String) throws -> Double {
    guard let v = Double(raw) else {
        throw ValidationError("volume must be numeric: 0-100 or a decimal 0.0-1.0")
    }
    let scalar = raw.contains(".") ? v : v / 100
    guard (0.0...1.0).contains(scalar) else {
        throw ValidationError("volume out of range: use 0-100 or 0.0-1.0")
    }
    return scalar
}

func parseRateValue(_ raw: String) throws -> Double {
    let t = raw.lowercased().trimmingCharacters(in: .whitespaces)
    let value: Double?
    if t.hasSuffix("khz") {
        value = Double(t.dropLast(3)).map { $0 * 1000 }
    } else if t.hasSuffix("k") {
        value = Double(t.dropLast()).map { $0 * 1000 }
    } else if t.hasSuffix("hz") {
        value = Double(t.dropLast(2))
    } else {
        value = Double(t)
    }
    guard let hz = value, hz > 0 else {
        throw ValidationError("invalid sample rate '\(raw)' — use e.g. 48000, 44.1k, 96kHz")
    }
    return hz
}
