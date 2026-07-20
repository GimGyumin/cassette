// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

struct SearchView: View {
    @Environment(\.appContainer) private var container
    @Environment(\.colorScheme) private var colorScheme
    
    // MainTabView로부터 바인딩으로 넘겨받는 변수들
    @Binding var searchQuery: String
    @Binding var path: NavigationPath
    
    var body: some View {
        VStack {
            Text("검색 화면")
                .font(.title)
                .bold()
            
            TextField("검색어를 입력하세요", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .padding()
            
            Spacer()
        }
        .navigationTitle("검색")
    }
}
