//
//  Debouncer.swift
//  ChromaFlow
//
//  Generic debouncer utility for high-frequency events like slider input.
//  Thread-safe with actor isolation.
//

import Foundation

/// Actor-based debouncer that coalesces rapid function calls
actor Debouncer {
    private var task: Task<Void, Never>?
    private let delay: TimeInterval

    /// Initialize debouncer with delay
    /// - Parameter delay: Delay in seconds (default 16ms for 60Hz)
    init(delay: TimeInterval = 0.016) {
        self.delay = delay
    }

    /// Debounce a function call
    /// - Parameter action: The action to debounce
    func debounce(_ action: @escaping @Sendable () -> Void) {
        // Cancel previous pending task
        task?.cancel()

        // Schedule new task
        task = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            guard !Task.isCancelled else { return }
            action()
        }
    }

    /// Cancel any pending debounced action
    func cancel() {
        task?.cancel()
        task = nil
    }
}
