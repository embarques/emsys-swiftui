import Network
import Observation

@MainActor
@Observable
final class NetworkConnection {
    enum Status: Equatable { case unknown, available, unavailable }
    private(set) var status: Status = .unknown
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var isStarted = false

    /// Starts publishing network path updates once for the app.
    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let unavailable = path.status == .unsatisfied
            Task { @MainActor [weak self] in
                // A path that is neither satisfied nor unsatisfied is still being evaluated.
                if available {
                    self?.status = .available
                } else if unavailable {
                    self?.status = .unavailable
                } else {
                    self?.status = .unknown
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "EMSYS.NetworkConnection"))
    }
}
