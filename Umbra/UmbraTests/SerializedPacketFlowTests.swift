import Foundation
import NetworkExtension
import Synchronization
import Testing
@testable import Umbra

private final class FakePacketFlow: NEPacketTunnelFlow, @unchecked Sendable {
    private let callback = Mutex<(@Sendable ([Data], [NSNumber]) -> Void)?>(nil)

    override func readPackets(completionHandler: @escaping @Sendable ([Data], [NSNumber]) -> Void) {
        callback.withLock { $0 = completionHandler }
    }

    func deliver() {
        let completion = callback.withLock { value in
            let completion = value
            value = nil
            return completion
        }
        completion?([Data([0x45])], [2])
    }
}

private final class PacketTally: Sendable {
    let value = Mutex(0)
}

struct SerializedPacketFlowTests {
    @Test(arguments: [false, true])
    func lateReadsAreDiscardedAfterInvalidation(invalidate: Bool) async {
        let result: Int = await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "Umbra.packetFlow.test")
            let base = FakePacketFlow()
            let flow = SerializedPacketFlow(flow: base, queue: queue)
            let tally = PacketTally()
            queue.async {
                flow.readPackets { packets, _ in tally.value.withLock { $0 += packets.count } }
                base.deliver()
                if invalidate { flow.invalidate() }
                queue.async {
                    // Retain the adapter until its queued read has run.
                    _ = flow
                    continuation.resume(returning: tally.value.withLock { $0 })
                }
            }
        }
        #expect(result == (invalidate ? 0 : 1))
    }
}
