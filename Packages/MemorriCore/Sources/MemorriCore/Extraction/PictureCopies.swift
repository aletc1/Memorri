import Foundation

/// The two JPEG copies of a picture the model is sent, made from the stored analysis copy (HEIC): the extraction call
/// gets it as it is, the classification call gets it at 1024 pixels (spike S2). The queue job and `memorri-eval` both
/// use this, so they send the same bytes.
struct PictureCopies {
    /// The classification call is sent at this size whatever the analysis size is.
    static let classificationLongEdge = 1024

    let classificationJPEG: Data
    let classificationSize: (width: Int, height: Int)
    let analysisJPEG: Data
    let analysisSize: (width: Int, height: Int)

    init(analysisCopy data: Data, width: Int, height: Int) throws {
        classificationJPEG = try PictureConverter.jpegData(from: data, longEdge: Self.classificationLongEdge)
        analysisJPEG = try PictureConverter.jpegData(from: data)
        let scale = min(1, Double(Self.classificationLongEdge) / Double(max(1, max(width, height))))
        classificationSize = (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
        analysisSize = (width, height)
    }
}
