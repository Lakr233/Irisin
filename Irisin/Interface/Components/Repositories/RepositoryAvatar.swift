//
//  RepositoryAvatar.swift
//  Irisin
//

import ImageIO
import UIKit

/// A repository's icon as a row draws it: the avatar scaled down to the row
/// once, off the main actor, and kept. An avatar is whatever the server
/// sent, 2048-pixel photographs among them, and a `UIImage(data:)` of one
/// is decoded whole, on the main thread, in the commit after every redraw:
/// a list of a hundred repositories dropped frames through every refresh.
enum RepositoryAvatar {
    /// The icon's longest side in pixels: the row's 33 points at 3x.
    static let pixelSize = 99

    private struct Entry {
        /// What `image` was made from; a refresh that brings another
        /// avatar makes it again.
        let data: Data
        /// Nil for data ImageIO cannot read.
        let image: UIImage?
    }

    /// One small picture per repository: a hundred of them are a few
    /// megabytes, so nothing is ever let go.
    private static var entries: [URL: Entry] = [:]
    private static var decoding: [URL: (data: Data, task: Task<UIImage?, Never>)] = [:]

    /// The icon made from `data` if it has been made; `.some(nil)` when the
    /// data is no picture.
    static func cached(for url: URL, data: Data) -> UIImage?? {
        guard let entry = entries[url], entry.data == data else { return nil }
        return .some(entry.image)
    }

    /// The icon made from `data`, made at most once however many rows ask.
    static func icon(for url: URL, data: Data) async -> UIImage? {
        if let cached = cached(for: url, data: data) {
            return cached
        }
        if let pending = decoding[url], pending.data == data {
            return await pending.task.value
        }
        let task = Task { await downsample(data, to: pixelSize) }
        decoding[url] = (data, task)
        let image = await task.value
        entries[url] = Entry(data: data, image: image)
        if decoding[url]?.data == data {
            decoding[url] = nil
        }
        return image
    }

    /// Decodes only as many pixels as the icon shows: a JPEG is read at a
    /// fraction of its size, and nothing full size stays in memory.
    @concurrent
    private nonisolated static func downsample(_ data: Data, to pixelSize: Int) async -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: pixelSize,
              ] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: image)
    }
}
