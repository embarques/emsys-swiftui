import Network
import Observation

@MainActor
@Observable
final class NetworkConnection {
    enum Status: Equatable { case unknown, available, unavailable }
    private(set) var status: Status = .unknown
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let unavailable = path.status == .unsatisfied
            Task { @MainActor [weak self] in
                self?.status = available ? .available : (unavailable ? .unavailable : .unknown)
            }
        }
        monitor.start(queue: DispatchQueue(label: "EMSYS.NetworkConnection"))
    }
}
