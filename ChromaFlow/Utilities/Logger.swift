import os.log

extension Logger {
    private static let subsystem = "com.chromaflow.ChromaFlow"

    static let display = Logger(subsystem: subsystem, category: "display")
    static let ddc = Logger(subsystem: subsystem, category: "ddc")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let automation = Logger(subsystem: subsystem, category: "automation")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let colorSync = Logger(subsystem: subsystem, category: "colorSync")
}
