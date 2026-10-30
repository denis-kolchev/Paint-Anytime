enum GalleryDebug {
    /// One switch for gallery fixtures, FPS, zoom diagnostics, and touch circles.
    #if DEBUG
    static let isEnabled = true
    #else
    static let isEnabled = false
    #endif
}
