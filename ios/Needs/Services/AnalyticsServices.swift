import Foundation

public actor NoOpAnalyticsService: AnalyticsService {
    public init() {}
    public func track(_ event: AnalyticsEvent, properties: [String: String] = [:]) async {}
}

public actor RecordingAnalyticsService: AnalyticsService {
    public struct Record: Equatable, Sendable {
        public let event: AnalyticsEvent
        public let properties: [String: String]
        public let timestamp: Date
    }

    private var records: [Record] = []
    public init() {}

    public func track(_ event: AnalyticsEvent, properties: [String: String] = [:]) async {
        records.append(Record(event: event, properties: properties, timestamp: .now))
    }

    public func capturedEvents() -> [Record] { records }
}
