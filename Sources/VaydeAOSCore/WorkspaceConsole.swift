import Foundation

public struct WorkspaceEvent: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var date = Date()
    public let title: String

    public init(title: String) { self.title = title }
}

/// Absolute deadlines let each workspace's timer survive navigation and relaunch.
public struct WorkspaceFocusTimer: Codable, Equatable, Sendable {
    public var duration = 25
    public var remaining: TimeInterval = 25 * 60
    public var deadline: Date?

    public func seconds(at date: Date) -> Int {
        max(0, Int(ceil(deadline?.timeIntervalSince(date) ?? remaining)))
    }

    public mutating func toggle(at date: Date) {
        if let deadline {
            remaining = max(0, deadline.timeIntervalSince(date))
            self.deadline = nil
        } else {
            if remaining <= 0 { remaining = Double(duration * 60) }
            deadline = date.addingTimeInterval(remaining)
        }
    }

    public mutating func reset(minutes: Int? = nil) {
        if let minutes { duration = minutes }
        remaining = Double(duration * 60)
        deadline = nil
    }

    @discardableResult
    public mutating func complete(at date: Date) -> Bool {
        guard let deadline, date >= deadline else { return false }
        self.deadline = nil
        remaining = 0
        return true
    }
}

public struct WorkspaceConsoleState: Codable, Equatable, Sendable {
    public var scratchpad = ""
    public var timer = WorkspaceFocusTimer()
    public var events: [WorkspaceEvent] = []
    public var autoIdle = true
    public var sidebarVisible = true

    public init() {}

    public mutating func record(_ title: String) {
        events.append(WorkspaceEvent(title: title))
        if events.count > 40 { events.removeFirst(events.count - 40) }
    }
}
