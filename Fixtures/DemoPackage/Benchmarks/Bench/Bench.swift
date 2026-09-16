import Benchmark
import Demo

nonisolated(unsafe) let benchmarks = {
    Benchmark("CountWords",
              configuration: .init(metrics: [.wallClock, .mallocCountTotal, .instructions],
                                   maxDuration: .seconds(1),
                                   maxIterations: 200)) { benchmark in
        let input = String(repeating: "The Quick, Brown Fox! jumps over 2 lazy dogs. ", count: 200)
        for _ in benchmark.scaledIterations { blackHole(countWords(input)) }
    }
}
