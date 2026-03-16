import MacmonSwift

struct MetricsRingBuffer {
    let capacity: Int
    private var storage: [Metrics?]
    private var head: Int = 0
    private(set) var count: Int = 0

    init(capacity: Int) {
        precondition(capacity > 0, "MetricsRingBuffer capacity must be greater than zero")
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    mutating func append(_ metrics: Metrics) {
        if count < capacity {
            let insertIndex = (head + count) % capacity
            storage[insertIndex] = metrics
            count += 1
            return
        }

        storage[head] = metrics
        head = (head + 1) % capacity
    }

    func snapshot() -> [Metrics] {
        guard count > 0 else { return [] }

        var result: [Metrics] = []
        result.reserveCapacity(count)

        for offset in 0..<count {
            let index = (head + offset) % capacity
            if let metrics = storage[index] {
                result.append(metrics)
            }
        }

        return result
    }

    mutating func removeAll() {
        storage = Array(repeating: nil, count: capacity)
        head = 0
        count = 0
    }
}
