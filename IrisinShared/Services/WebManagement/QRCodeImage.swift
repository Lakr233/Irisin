//
//  QRCodeImage.swift
//  Irisin
//

import CoreImage
import UIKit

/// The QR code of the page's address with the code in its fragment, drawn
/// with no smoothing so a camera reads it from across a room. CoreImage's
/// generator, which iOS and tvOS both have.
enum QRCodeImage {
    static func make(_ text: String, side: CGFloat, scale: CGFloat) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = filter.outputImage else { return nil }
        let factor = (side * scale / code.extent.width).rounded(.down)
        let scaled = code.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        // the GPU's renderer, then the CPU's: an Apple TV guest with no
        // Metal device drew an empty square
        let rendered = [false, true].lazy.compactMap { software in
            CIContext(options: [.useSoftwareRenderer: software]).createCGImage(scaled, from: scaled.extent)
        }
        guard let image = rendered.first else { return nil }
        return UIImage(cgImage: image, scale: scale, orientation: .up)
    }
}
