enum OnboardingStage: Int, CaseIterable, Hashable, Sendable {
    case agents
    case notifications
    case pairing
    case connect

    var previous: Self? { Self(rawValue: rawValue - 1) }
    var next: Self? { Self(rawValue: rawValue + 1) }

    var position: Int { rawValue + 1 }

    var analyticsValue: String {
        switch self {
        case .agents: "agents"
        case .notifications: "notifications"
        case .pairing: "pairing"
        case .connect: "connect"
        }
    }
}
