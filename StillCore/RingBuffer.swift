struct RingBuffer<Element> {
    let capacity: Int
    private(set) var count: Int = 0
    private(set) var appendedCount: Int = 0
    private var head: Int = 0
    private var storage: [Element?]

    init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be greater than zero")
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    mutating func append(_ element: Element) {
        let insertIndex: Int

        if count < capacity {
            insertIndex = (head + count) % capacity
            count += 1
        } else {
            insertIndex = head
            head = (head + 1) % capacity
        }

        storage[insertIndex] = element
        appendedCount += 1
    }

    func snapshot() -> [Element] {
        guard count > 0 else { return [] }

        var result: [Element] = []
        result.reserveCapacity(count)

        for offset in 0..<count {
            let index = (head + offset) % capacity
            if let element = storage[index] {
                result.append(element)
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
