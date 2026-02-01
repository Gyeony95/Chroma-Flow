import SwiftUI

protocol UIThemeProviding {
    associatedtype PopoverMaterial: View
    func popoverMaterial() -> PopoverMaterial
    func interactionSpring() -> Animation
    var supportsAdaptiveGlass: Bool { get }
}
