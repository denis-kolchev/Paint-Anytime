enum GalleryDebug {
    /// One switch for gallery fixtures, FPS, zoom diagnostics, and touch circles.
    #if DEBUG
    nonisolated static let isEnabled = true
    #else
    nonisolated static let isEnabled = false
    #endif
}
