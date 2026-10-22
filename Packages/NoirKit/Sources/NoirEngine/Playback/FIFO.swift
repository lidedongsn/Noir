/// 先进先出队列，出队复杂度 O(1)。
struct FIFO<Element> {
    private var items: [Element] = []
    private var head = 0

    var isEmpty: Bool { head == items.count }
    var count: Int { items.count - head }

    mutating func push(_ item: Element) {
        items.append(item)
    }

    mutating func pop() -> Element? {
        guard head < items.count else { return nil }
        let item = items[head]
        head += 1
        // 已出队元素过半时压缩存储
        if head > 64, head * 2 > items.count {
            items.removeFirst(head)
            head = 0
        }
        return item
    }

    mutating func removeAll() {
        items.removeAll(keepingCapacity: true)
        head = 0
    }
}
