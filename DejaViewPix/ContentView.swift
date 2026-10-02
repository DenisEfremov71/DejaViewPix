//
//  ContentView.swift
//  DejaViewPix
//
//  Created by Denis Efremov on 2026-10-01.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            PhotoSearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            ChatView()
                .tabItem { Label("Chat", systemImage: "text.bubble") }
            APIKeyView()
                .tabItem { Label("API Key", systemImage: "key") }
        }
    }
}

#Preview {
    ContentView()
}
