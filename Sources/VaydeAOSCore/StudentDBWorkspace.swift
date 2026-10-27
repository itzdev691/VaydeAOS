import Foundation

/// StudentDB's learning tools are selected per workspace, never as a global mode.
public enum StudentDBWorkspace {
    public static let buildDirectory = "build/vaydeaos"
    public static let buildCommand = "cmake -S . -B build/vaydeaos -DCMAKE_BUILD_TYPE=Debug -DCMAKE_CXX_FLAGS='-Wall -Wextra' && cmake --build build/vaydeaos --parallel"
    public static let executable = "build/vaydeaos/studentdb"

    public static func matches(name: String, directory: String) -> Bool {
        let names = [name, URL(fileURLWithPath: directory).lastPathComponent].map { $0.lowercased() }
        return names.contains { $0 == "studentdb" || $0 == "studentdb(deploy)" }
    }

    public struct Source: Identifiable, Sendable {
        public var id: String { path }
        public let title: String
        public let path: String
        public let detail: String
    }

    public static let sources: [Source] = [
        .init(title: "Menu & dispatch", path: "src/main.cpp", detail: "Trace the returned choice into enrollment or login."),
        .init(title: "Terminal input", path: "src/terminal.cpp", detail: "Follow local scope, string return values, and input."),
        .init(title: "Enrollment", path: "src/enrollment/enrollment.cpp", detail: "Step through fields, validation, and confirmation."),
        .init(title: "Login", path: "src/login/login.cpp", detail: "Follow credential comparison and failure returns."),
        .init(title: "Student types", path: "include/student.h", detail: "Read structs, extern declarations, and function signatures."),
        .init(title: "Validation", path: "src/student.cpp", detail: "Inspect birthdate and grade checks."),
        .init(title: "Record writer", path: "src/recordgen.cpp", detail: "Trace append mode and the relative students.txt path."),
        .init(title: "CMake target", path: "CMakeLists.txt", detail: "Connect declarations, compilation, and linking.")
    ]

    public static func readSource(_ path: String, directory: String) -> String? {
        guard sources.contains(where: { $0.path == path }) else { return nil }
        let root = URL(fileURLWithPath: directory).resolvingSymlinksInPath()
        let url = root.appendingPathComponent(path).resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// Each workspace restores its own source selection and output tab.
public struct StudentDBConsoleState: Codable, Equatable, Sendable {
    public var sourcePath = "src/main.cpp"
    public var selectedTab = "SOURCE TRACE"
    public init() {}
}
