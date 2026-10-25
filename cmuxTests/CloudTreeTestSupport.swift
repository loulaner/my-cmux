import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension Array where Element == CloudTreeNode {
    /// Removes an explicitly supplied CodeRouter section when a fixture is
    /// asserting only the machine/device tree shape.
    var withoutCoderouterSection: [CloudTreeNode] {
        filter { $0.id != "coderouter-section" && !$0.id.hasPrefix("coderouter-section/") }
    }
}
