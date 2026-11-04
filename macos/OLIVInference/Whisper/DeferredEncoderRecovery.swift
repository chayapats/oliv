/// Keep recovery weights unloaded until an uncancelled request needs them.
/// Only a successful installation consumes the loader; cancellation or a load
/// failure leaves it available for the next request.
final class DeferredEncoderRecovery<Encoder> {
    private var load: (() throws -> Encoder)?

    init(load: @escaping () throws -> Encoder) { self.load = load }

    func restore(checkCancellation: () throws -> Void, install: (Encoder) throws -> Void) throws {
        guard let load else { return }
        try checkCancellation()
        try install(load())
        self.load = nil
    }
}
