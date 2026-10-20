import Foundation

/// One step of Claude's plan as the app shows it: who does it, where it stands (a step handed to a worker follows its
/// task live), and one line of detail: what the worker is doing now, why it waits, what it found.
public struct PlanItem: Identifiable, Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        /// Not started.
        case pending
        /// Being done now, by Claude or by its worker.
        case active
        /// Handed out, waiting in its worker's queue (each worker runs one task at a time).
        case queued
        /// Waiting on you: a question, or approval to load its worker's model.
        case needsYou
        /// The worker finished; Claude reviews the result before it marks the step done.
        case review
        case done
        case failed
        case cancelled
    }

    public let step: PlanStep
    public let phase: Phase
    /// The task doing it, once handed out.
    public let task: TaskEvent?
    public let detail: String?
    public var id: String { step.id }
    /// Who does it: "lead" (Claude) or the worker the task went to.
    public var owner: String { task?.worker ?? step.owner }
}

/// A plan at a glance: how far along it is, what's happening now, and Claude's own next step.
public struct PlanSummary: Equatable, Sendable {
    public let done: Int
    public let total: Int
    /// Steps being done now, or waiting on you.
    public let now: [PlanItem]
    /// Handed out and waiting their turn.
    public let queued: Int
    /// Claude's next step of its own.
    public let next: PlanItem?
    public let needsYou: Int
}

extension DuetStore {
    /// A conversation's plan, each step with its live state.
    public func planItems(_ conversationId: String) -> [PlanItem] {
        (conversation(conversationId)?.plan ?? []).map(planItem)
    }

    public func planSummary(_ conversationId: String) -> PlanSummary? {
        let items = planItems(conversationId)
        guard !items.isEmpty else { return nil }
        return PlanSummary(
            done: items.filter { $0.phase == .done }.count, total: items.count,
            now: items.filter { [.active, .needsYou, .review].contains($0.phase) },
            queued: items.filter { $0.phase == .queued }.count,
            next: items.first { $0.step.isClaudes && $0.phase == .pending },
            needsYou: items.filter { $0.phase == .needsYou }.count)
    }

    /// The conversation's tasks no plan step names (yours, Claude's subagents, any from before the plan), newest first.
    public func unplannedTasks(_ conversationId: String) -> [TaskEvent] {
        guard let c = conversation(conversationId) else { return [] }
        let planned = Set(c.plan.compactMap(\.taskId))
        return c.taskIds.reversed().filter { !planned.contains($0) }.compactMap { tasks[$0] }
    }

    func planItem(_ s: PlanStep) -> PlanItem {
        let task = s.taskId.flatMap { tasks[$0] }
        func item(_ phase: PlanItem.Phase, _ detail: String?) -> PlanItem { PlanItem(step: s, phase: phase, task: task, detail: detail) }
        if s.status == "completed" { return item(.done, s.note ?? task.flatMap(resultGist)) }
        guard let task else { return item(s.status == "in_progress" ? .active : .pending, s.note) }
        switch task.state {
        case "queued":
            let ahead = task.queuePosition ?? 0
            return item(.queued, ahead > 0 ? "Waits for \(ahead == 1 ? "the task" : "\(ahead) tasks") ahead of it: its worker runs one at a time" : "Starting")
        case "awaiting_swap":
            return item(.needsYou, "Waits for you to approve loading its worker's model")
        case "running":
            if attention.contains(where: { if case .question(let q) = $0 { q.taskId == task.taskId } else { false } }) {
                return item(.needsYou, openQuestions.last { $0.taskId == task.taskId }.map { "Asks: \($0.text)" } ?? "Asks you a question")
            }
            return item(.active, workerActivity[task.worker] ?? s.note)
        case "done": return item(.review, resultGist(task) ?? s.note)
        case "failed": return item(.failed, task.error ?? resultGist(task) ?? s.note)
        case "cancelled": return item(.cancelled, s.note)
        default: return item(.active, s.note)
        }
    }

    /// The first line of what a task reported: its RESULT card's summary, else its result.
    func resultGist(_ t: TaskEvent) -> String? {
        let text = cards.last { $0.taskId == t.taskId && $0.kind == "RESULT" }.map { ResultParts($0.text).summary } ?? t.result
        return text?.split(separator: "\n").first.map { String($0.prefix(160)) }
    }
}
