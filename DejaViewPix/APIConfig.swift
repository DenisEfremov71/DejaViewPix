//
//  APIConfig.swift
//  DejaViewPix
//
//  Created by Denis Efremov on 2026-10-01.
//

import Foundation

nonisolated enum ConfigError: LocalizedError {
    case missingAPIKey
    case placeholderAPIKey
    
    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Claude API key missing. Copy Secrets.example.xcconfig to Secrets.xcconfig and add your key."
        case .placeholderAPIKey:
            return "Claude API key is still the placeholder. Replace \"your-key-here\" in Secrets.xcconfig with your real key from the Claude Console."
        }
    }
}

nonisolated enum APIConfig {
    private static let infoKey = "ClaudeAPIKey"
    private static let placeholder = "your-key-here"
    
    static func claudeAPIKey() throws -> String {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: infoKey) as? String else {
            throw ConfigError.missingAPIKey
        }
        
        let key = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !key.isEmpty else {
            throw ConfigError.missingAPIKey
        }
        
        guard key != placeholder else {
            throw ConfigError.placeholderAPIKey
        }
        
        return key
    }
}
