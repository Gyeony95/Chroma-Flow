import Foundation
import CoreGraphics

protocol DisplayDetecting: Sendable {
    var events: AsyncStream<DisplayEvent> { get }
    func connectedDisplays() async -> [DisplayDevice]
}

enum DisplayEvent: Sendable {
    case connected(DisplayDevice)
    case disconnected(CGDirectDisplayID)
    case profileChanged(CGDirectDisplayID)
}
