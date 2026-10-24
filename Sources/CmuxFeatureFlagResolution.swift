struct CmuxFeatureFlagResolution: Equatable, Sendable {
    let effectiveValue: Bool
    let source: CmuxFeatureFlagSource
    let allowsLocalOverride: Bool

    init(
        overrideValue: Bool?,
        defaultValue: Bool,
        overridePolicy: CmuxFeatureFlagOverridePolicy = .localFirst
    ) {
        allowsLocalOverride = overridePolicy == .localFirst
        if allowsLocalOverride, let overrideValue {
            effectiveValue = overrideValue
            source = CmuxFeatureFlagSource.override
        } else {
            effectiveValue = defaultValue
            source = CmuxFeatureFlagSource.default
        }
    }
}
