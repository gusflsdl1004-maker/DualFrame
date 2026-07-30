//
//  ContentView.swift
//  DualFrame
//

import SwiftUI

struct ContentView: View {
    /// Task 070 requirement 3: short-form generation must survive the user leaving the
    /// camera screen, so its coordinator is owned here at the app root rather than by
    /// `CameraPreviewView`. Anything presented over the camera — library, settings —
    /// reads the same instance.
    @StateObject private var shortGenerationCoordinator: ShortGenerationCoordinator
    private let libraryService: InternalVideoLibraryService

    init() {
        let libraryService = InternalVideoLibraryService()
        self.libraryService = libraryService
        _shortGenerationCoordinator = StateObject(
            wrappedValue: ShortGenerationCoordinator(libraryService: libraryService)
        )
    }

    var body: some View {
        CameraPreviewView(
            libraryService: libraryService,
            shortGenerationCoordinator: shortGenerationCoordinator
        )
    }
}

#Preview {
    ContentView()
}
