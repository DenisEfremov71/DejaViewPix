//
//  ClaudeError.swift
//  AlbumAI
//

import Foundation

public enum ClaudeError: LocalizedError, Sendable, Equatable {
    /// A non-2xx response. `type` and `message` come from the error body when it could be decoded.
    case http(
        status: Int,
        type: String?,
        message: String?,
        requestID: String?,
        retryAfter: Duration?
    )
    case invalidResponse
    case noTextContent(stopReason: String?)
    /// An `error` event arrived in the middle of a stream.
    case stream(type: String, message: String)
    /// The stream ended before `message_stop`.
    case streamInterrupted

    public var errorDescription: String? {
        switch self {
        case .http(let status, let type, let message, let requestID, _):
            var description: String
            if let message {
                let typeLabel = type.map { ", \($0)" } ?? ""
                description = "Claude API error (HTTP \(status)\(typeLabel)): \(message)"
            } else {
                description = "Claude API returned HTTP \(status) with no error details."
            }
            if let requestID {
                description += "\nRequest ID: \(requestID)"
            }
            return description

        case .invalidResponse:
            return "Unexpected response from the server (not an HTTP response)."

        case .noTextContent(let stopReason):
            if stopReason == "refusal" {
                return "Claude declined this request."
            }
            return "Claude responded, but the reply contained no text."

        case .stream(let type, let message):
            return "The reply stopped with an error (\(type)): \(message)"

        case .streamInterrupted:
            return "The connection closed before the reply finished."
        }
    }
}
