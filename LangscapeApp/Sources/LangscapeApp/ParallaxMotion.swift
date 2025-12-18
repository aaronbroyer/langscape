#if canImport(CoreMotion)
import CoreMotion
#endif

#if canImport(SwiftUI)
import SwiftUI

@MainActor
final class MotionManager: ObservableObject {
    #if canImport(CoreMotion)
    private let manager = CMMotionManager()
    #endif

    @Published var pitch: Double = 0
    @Published var roll: Double = 0

    init() {
        #if canImport(CoreMotion)
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        guard manager.isDeviceMotionAvailable else { return }
        manager.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            withAnimation(.linear(duration: 0.1)) {
                self.pitch = data.attitude.pitch
                self.roll = data.attitude.roll
            }
        }
        #endif
    }

    deinit {
        #if canImport(CoreMotion)
        manager.stopDeviceMotionUpdates()
        #endif
    }
}
#endif

