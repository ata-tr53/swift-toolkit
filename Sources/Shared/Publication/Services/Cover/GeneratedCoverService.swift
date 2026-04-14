//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A `CoverService` which holds a lazily generated cover bitmap in memory.
public final class GeneratedCoverService: CoverService {
    enum Error: Swift.Error {
        case generationFailed
    }

    private var _cover: ReadResult<PlatformImage>?
    private let makeCover: () async -> ReadResult<PlatformImage>

    public init(makeCover: @escaping () async -> ReadResult<PlatformImage>) {
        self.makeCover = makeCover
    }

    public convenience init(cover: PlatformImage) {
        self.init(makeCover: { .success(cover) })
    }

    private let coverLink = Link(
        href: "~readium/cover",
        mediaType: .png,
        rel: .cover
    )

    private func cachedCover() async -> ReadResult<PlatformImage> {
        if _cover == nil {
            _cover = await makeCover()
        }
        return _cover!
    }

    public func cover() async -> ReadResult<PlatformImage?> {
        await cachedCover().map { $0 as PlatformImage? }
    }

    public var links: [Link] {
        [coverLink]
    }

    public func get<T: URLConvertible>(_ href: T) -> (any Resource)? {
        guard href.anyURL.isEquivalentTo(coverLink.url()) else {
            return nil
        }

        return CoverResource(cover: cachedCover)
    }

    public static func makeFactory(makeCover: @escaping () async -> ReadResult<PlatformImage>) -> (PublicationServiceContext) -> GeneratedCoverService? {
        { _ in GeneratedCoverService(makeCover: makeCover) }
    }

    public static func makeFactory(cover: PlatformImage) -> (PublicationServiceContext) -> GeneratedCoverService? {
        { _ in GeneratedCoverService(cover: cover) }
    }

    private class CoverResource: Resource {
        private let cover: () async -> ReadResult<PlatformImage>

        init(cover: @escaping () async -> ReadResult<PlatformImage>) {
            self.cover = cover
        }

        let sourceURL: AbsoluteURL? = nil

        func estimatedLength() async -> ReadResult<UInt64?> {
            .success(nil)
        }

        func properties() async -> ReadResult<ResourceProperties> {
            .success(ResourceProperties())
        }

        func stream(range: Range<UInt64>?, consume: @escaping (Data) -> Void) async -> ReadResult<Void> {
            await cover().flatMap {
                guard let data = $0.pngData() else {
                    return .failure(.decoding("Failed to convert the cover bitmap to PNG data"))
                }
                consume(data)
                return .success(())
            }
        }
    }
}
