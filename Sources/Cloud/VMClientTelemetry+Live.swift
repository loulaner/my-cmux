import CmuxCloud
import CmuxProductAnalytics
import Foundation

extension VMClientTelemetry {
    /// The production telemetry: PostHog for captured requests and product
    /// analytics for the Cloud funnel.
    /// Built once at the composition root.
    static func live() -> VMClientTelemetry {
        VMClientTelemetry(
            capturePostHog: { event, properties in
                PostHogAnalytics.shared.capture(event, properties: properties)
            },
            observeRecord: { record in
                ProductAnalytics.app.noteCloudRequest(CloudRequestObservation(
                    method: record.method,
                    route: record.route,
                    success: record.outcome.isSuccess,
                    errorCode: record.outcome.errorCode,
                    durationMs: record.durationMs
                ))
            }
        )
    }
}
