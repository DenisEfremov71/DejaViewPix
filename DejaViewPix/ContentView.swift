//
//  ContentView.swift
//  DejaViewPix
//
//  Created by Denis Efremov on 2026-10-01.
//

import SwiftUI

struct ContentView: View {
    enum Tab {
        case search, chat, apiKey
    }

    @State private var tab = Tab.search

    var body: some View {
        TabView(selection: $tab) {
            PhotoSearchView(showAPIKey: { tab = .apiKey })
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)
            ChatView()
                .tabItem { Label("Chat", systemImage: "text.bubble") }
                .tag(Tab.chat)
            APIKeyView()
                .tabItem { Label("API Key", systemImage: "key") }
                .tag(Tab.apiKey)
        }
    }
}

#Preview {
    ContentView()
}
