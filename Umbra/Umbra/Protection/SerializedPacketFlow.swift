import Foundation
@preconcurrency import NetworkExtension

// Read callbacks and invalidation share the lifecycle queue; writes use Apple's thread-safe flow.
nonisolated final class SerializedPacketFlow: NEPacketTunnelFlow, @unchecked Sendable {
    private let flow: NEPacketTunnelFlow
    private let queue: DispatchQueue
    private var active = true

    init(flow: NEPacketTunnelFlow, queue: DispatchQueue) {
        self.flow = flow
        self.queue = queue
        super.init()
    }

    func invalidate() {
        dispatchPrecondition(condition: .onQueue(queue))
        active = false
    }

    override func readPackets(completionHandler: @escaping @Sendable ([Data], [NSNumber]) -> Void) {
        flow.readPackets { [weak self] packets, protocols in
            self?.queue.async { [weak self] in
                guard let self, self.active else { return }
                completionHandler(packets, protocols)
            }
        }
    }

    override func writePackets(_ packets: [Data], withProtocols protocols: [NSNumber]) -> Bool {
        flow.writePackets(packets, withProtocols: protocols)
    }
}
