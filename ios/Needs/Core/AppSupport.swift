import Foundation

public enum AppError: LocalizedError, Equatable, Sendable {
    case invalidInput(String)
    case authenticationRequired
    case notFound
    case unavailable(String)
    case offline
    case conflict(String)
    case paymentFailed
    case permissionDenied
    case configurationMissing(String)
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput:
            "Please check what you entered and try again."
        case .authenticationRequired:
            "Please sign in to continue."
        case .notFound:
            "We couldn't find that right now."
        case .unavailable:
            "This item is no longer available."
        case .offline:
            "Connect to the internet and try again."
        case .conflict:
            "This changed elsewhere. Refresh and try again."
        case .paymentFailed:
            "The payment couldn't be completed."
        case .permissionDenied:
            "Permission is needed to use this feature."
        case .configurationMissing:
            "This feature isn't configured yet."
        case .underlying:
            "Something went wrong. Please try again."
        }
    }

    public var technicalDescription: String {
        switch self {
        case .invalidInput(let value), .unavailable(let value), .conflict(let value),
             .configurationMissing(let value), .underlying(let value): value
        default: String(describing: self)
        }
    }
}

public enum LoadableState<Value: Sendable & Equatable>: Sendable, Equatable {
    case idle
    case loading
    case empty
    case loaded(Value)
    case offline(Value?)
    case failed(message: String)
}

public enum NeedsJSON {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

public enum CurrencyFormatter {
    public static func string(amount: Decimal, currency: String, locale: Locale = Locale(identifier: "en_US")) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.locale = locale
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(currency) \(amount)"
    }
}
