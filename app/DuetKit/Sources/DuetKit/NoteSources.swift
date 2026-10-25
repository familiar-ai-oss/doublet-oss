import Foundation

/// Turns the notes kept anywhere (the hub's annotations, whatever they were written on) into `NoteEntry`s, each
/// filed by the modules it's about. A note on a module's page is about that file; on a task's diff, the files it
/// marks; on a visual, the code its nodes stand for (the diagram's `links`, else what the diagram `explains`).
public enum NoteSources {
    /// The file a link names, with or without lines: "path:12", "path:12-20" or "path".
    public static func path(ofLink link: String) -> String? {
        let link = link.trimmingCharacters(in: .whitespaces)
        guard !link.isEmpty else { return nil }
        if let ref = CodeRef(link: link) { return ref.path }
        // "path:" or a path with no line.
        let path = link.hasSuffix(":") ? String(link.dropLast()) : link
        return path.isEmpty ? nil : path
    }

    /// The modules a kept note is about, the main one first, without repeats. `diagram` is the version it was written
    /// on (else the latest), `taskCwd` the folder of the task whose diff it's on, `base` the conversation's folder
    /// (relative paths are joined to it).
    public static func modules(of a: Annotation, diagram: DiagramEvent?, taskCwd: String?, base: String?) -> [String] {
        var out: [String] = []
        func add(_ path: String?, under folder: String? = nil) {
            guard let path, !path.isEmpty else { return }
            let full = absolute(path, base: folder ?? base)
            if !out.contains(full) { out.append(full) }
        }
        switch a.surface {
        case .file(let path):
            add(path)
            for l in a.lines ?? [] { add(l.file) }
        case .diff:
            for l in a.lines ?? [] { add(l.file, under: taskCwd) }
        case .diagram:
            // The nodes it was written on, each by what it stands for; else the code the whole diagram explains.
            for e in a.elements ?? [] { add(diagram?.links?[e.id].flatMap(path(ofLink:))) }
            if out.isEmpty { for ref in diagram?.explains ?? [] { add(ref.path) } }
        case .plan:
            break // a plan's steps don't name files yet
        }
        return out
    }

    /// Every kept note as an entry, deleted ones left out. `tags` are the tags kept on this device by note id (until
    /// tags travel with notes).
    public static func entries(_ annotations: [Annotation], diagram: (_ id: String, _ version: Int?) -> DiagramEvent?,
                               taskCwd: (_ taskId: String) -> String?, base: String?, tags: [String: [String]]) -> [NoteEntry] {
        annotations.filter { $0.deleted != true }.map { a in
            let d: DiagramEvent?, cwd: String?
            switch a.surface {
            case .diagram(let id, let version, _): d = diagram(id, version); cwd = nil
            case .diff(let taskId, _): d = nil; cwd = taskCwd(taskId)
            default: d = nil; cwd = nil
            }
            return NoteEntry(id: a.id, modules: modules(of: a, diagram: d, taskCwd: cwd, base: base), surface: a.surface,
                             node: a.elements?.first?.id, tags: tags[a.id] ?? [], createdAt: a.date, text: a.text ?? "",
                             question: a.intent == .question, resolved: a.resolved)
        }
    }

    /// The hub's entries with this device's: a note in both is the hub's (its status and time), with this device's
    /// tags when the hub has none; notes only here (not sent yet, or on a scratchpad) are added.
    public static func merged(hub: [NoteEntry], local: [NoteEntry]) -> [NoteEntry] {
        let mine = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out = hub.map { e -> NoteEntry in
            guard let l = mine[e.id] else { return e }
            var e = e
            if e.tags.isEmpty { e.tags = l.tags }
            if e.createdAt == nil { e.createdAt = l.createdAt }
            e.scratch = l.scratch
            return e
        }
        let seen = Set(hub.map(\.id))
        out += local.filter { !seen.contains($0.id) }
        return out
    }

    private static func absolute(_ path: String, base: String?) -> String {
        guard let base, !path.hasPrefix("/"), !path.hasPrefix("~") else { return path }
        return Paths.join(base, path)
    }
}
