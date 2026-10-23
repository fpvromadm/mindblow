import SwiftUI
import QuartzCore

/// Self-benchmark for the collapse/expand round trip, so its cost can be
/// measured inside a real SwiftUI render loop rather than guessed at from the
/// outside. Off unless `MINDBLOW_BENCH` is set to a node count:
///
///     MINDBLOW_BENCH=300 build/MindBlow.app/Contents/MacOS/MindBlow
///
/// It replaces the open document with a generated map, then toggles a large
/// branch repeatedly, timing each toggle from the mutation until the main
/// thread has finished the update it triggers. Results go to stderr.
enum CollapseBenchmark {
    static var requestedNodeCount: Int? {
        ProcessInfo.processInfo.environment["MINDBLOW_BENCH"].flatMap(Int.init)
    }

    static func makeTree(nodeCount: Int) -> MindNode {
        var made = 1
        func build(_ level: Int) -> MindNode {
            var n = MindNode(text: "Topic \(made) with a realistic label")
            made += 1
            if made < nodeCount, level < 4 {
                var kids: [MindNode] = []
                for _ in 0..<4 where made < nodeCount { kids.append(build(level + 1)) }
                n.children = kids
            }
            return n
        }
        var root = MindNode(text: "Central Topic")
        var kids: [MindNode] = []
        while made < nodeCount { kids.append(build(1)) }
        root.children = kids
        return root
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }

    /// Runs `toggle` repeatedly, measuring main-thread time from the mutation
    /// to the end of the resulting update, plus how many node bodies SwiftUI
    /// had to build for it.
    static func run(iterations: Int = 10, toggle: @escaping (Int) -> Void) {
        var samples: [(ms: Double, bodies: Int)] = []

        func step(_ i: Int) {
            guard i < iterations else {
                report(samples)
                return
            }
            NodeView.bodyEvaluations = 0
            let start = CACurrentMediaTime()
            toggle(i)
            // Runs once the main thread has drained the work this mutation
            // scheduled — body evaluation, layout, and view construction.
            DispatchQueue.main.async {
                let elapsed = (CACurrentMediaTime() - start) * 1000
                samples.append((elapsed, NodeView.bodyEvaluations))
                let action = i.isMultiple(of: 2) ? "collapse" : "expand  "
                log(String(format: "BENCH %@ #%02d  %7.1f ms  %4d node bodies built",
                           action, i, elapsed, NodeView.bodyEvaluations))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { step(i + 1) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { step(0) }
    }

    private static func report(_ samples: [(ms: Double, bodies: Int)]) {
        let collapses = samples.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
        let expands = samples.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map(\.element)
        func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
        log(String(format: "BENCH collapse mean %6.1f ms (%.0f bodies)",
                   mean(collapses.map(\.ms)), mean(collapses.map { Double($0.bodies) })))
        log(String(format: "BENCH expand   mean %6.1f ms (%.0f bodies)",
                   mean(expands.map(\.ms)), mean(expands.map { Double($0.bodies) })))
        exit(0)
    }
}
