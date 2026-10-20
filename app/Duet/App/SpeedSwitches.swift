import Foundation

/// Measuring aid for debug builds: `DUET_SPEED_OFF=replay,files,list,rows,pulse,taps,stills,apple,sections` turns those speed
/// fixes off, so the pressure tests measure each against the same build (docs/diagnostics.md). Release builds always have
/// them on.
///
/// - `replay`: a connection's replay handed over as one batch, a long one applied in slices (DuetKit's HubConnection
///   reads the same variable).
/// - `files`: a file tab shows its last read at once while it's read again. (Keeping web pages for reuse was tried
///   too, and measured no faster with 30 MB more memory, so it went.)
/// - `list`: the conversation list kept apart from the store, changing only when a row would read differently.
/// - `rows`: thread rows skipped when unchanged, their grouping and parsed Markdown kept.
/// - `pulse`: status symbols pulse with Core Animation instead of SwiftUI's per-frame symbol effect.
/// - `taps`: page taps act at once; the Pencil palette comes out once per page.
/// - `stills`: diagram cards in the thread show a still of the diagram, drawn once off screen and kept on disk, instead
///   of a live web page each (DiagramStills).
/// - `apple`: what the on-device model can do is read off the main thread when Duet connects
///   (AppleIntelligence.readStatus).
/// - `sections`: the thread's List in sections of 50 items, so finding a row's separator doesn't walk the whole thread
///   on every live-reply tick and new row (LeadThread.ThreadSection).
enum SpeedSwitches {
    #if DEBUG
    static let off: Set<String> = Set((ProcessInfo.processInfo.environment["DUET_SPEED_OFF"] ?? "")
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    #else
    static let off: Set<String> = []
    #endif

    static func on(_ fix: String) -> Bool { !off.contains(fix) }
}
