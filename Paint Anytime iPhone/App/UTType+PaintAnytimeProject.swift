import UniformTypeIdentifiers

extension UTType {
    static let paintAnytimeProject = UTType(exportedAs: PaintProject.typeIdentifier)
    /// Declared by the system; `psd` files conform to it.
    static let photoshopImage = UTType("com.adobe.photoshop-image")
        ?? UTType(filenameExtension: PhotoshopExport.fileExtension, conformingTo: .image) ?? .image
}
