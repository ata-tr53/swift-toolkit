//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import AVFoundation
import Foundation
import ReadiumShared

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Implements a strategy to augment a `Manifest` of an audio publication with additional metadata and
/// cover, for example by looking into the audio files metadata.
public protocol AudioPublicationManifestAugmentor {
    func augment(_ baseManifest: Manifest, using container: Container) async -> AudioPublicationAugmentedManifest
}

public struct AudioPublicationAugmentedManifest {
    public var manifest: Manifest
    public var cover: PlatformImage?

    public init(manifest: Manifest, cover: PlatformImage? = nil) {
        self.manifest = manifest
        self.cover = cover
    }
}

/// An `AudioPublicationManifestAugmentor` using AVFoundation to retrieve the audio metadata.
///
/// It will only work for local publications (file://).
public final class AVAudioPublicationManifestAugmentor: AudioPublicationManifestAugmentor {
    public init() {}
    
    #if os(macOS)
    public func augment(_ manifest: Manifest, using container: Container) async -> AudioPublicationAugmentedManifest {
        let avAssets = manifest.readingOrder.map { link -> AVURLAsset? in
            guard let fileURL = container[link.url()]?.sourceURL?.fileURL else { return nil }
            return AVURLAsset(url: fileURL.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        }
        
        var manifest = manifest
        var newReadingOrder: [Link] = []
        var allMetadata: [AVMetadataItem] = []
        var totalDuration: Double? = 0
        
        // 1. Process Reading Order and collect total metadata & duration asynchronously
        for (link, avAsset) in zip(manifest.readingOrder, avAssets) {
            guard let avAsset = avAsset else {
                newReadingOrder.append(link)
                totalDuration = nil // If any asset is missing, total duration becomes nil
                continue
            }
            
            var updatedLink = link
            
            // Await Metadata
            let metadata = (try? await avAsset.load(.metadata)) ?? []
            allMetadata.append(contentsOf: metadata)
            
            // Update Link Title
            for item in metadata.filter([.commonIdentifierTitle]) {
                if let str = try? await item.load(.stringValue), !str.isEmpty {
                    updatedLink.title = str
                    break
                }
            }
            
            // Update Link Duration
            if let duration = try? await avAsset.load(.duration) {
                updatedLink.duration = duration.seconds
                if let currentTotal = totalDuration {
                    totalDuration = currentTotal + duration.seconds
                }
            } else {
                totalDuration = nil
            }
            
            newReadingOrder.append(updatedLink)
        }
        
        manifest.readingOrder = newReadingOrder
        var metadata = manifest.metadata
        
        // MARK: - Async Helpers
        
        func firstString(for identifiers: [AVMetadataIdentifier]) async -> String? {
            for item in allMetadata.filter(identifiers) {
                if let str = try? await item.load(.stringValue), !str.isEmpty {
                    return str
                }
            }
            return nil
        }
        
        func allStrings(for identifiers: [AVMetadataIdentifier]) async -> [String] {
            var results: [String] = []
            for item in allMetadata.filter(identifiers) {
                if let str = try? await item.load(.stringValue), !str.isEmpty {
                    results.append(str)
                }
            }
            return results.removingDuplicates()
        }

        // MARK: - Update Global Metadata
        
        if let title = await firstString(for: [.commonIdentifierTitle, .id3MetadataAlbumTitle]) {
            metadata.localizedTitle = title.localizedString
        }
        
        if let subtitle = await firstString(for: [.id3MetadataSubTitle, .iTunesMetadataTrackSubTitle]) {
            metadata.localizedSubtitle = subtitle.localizedString
        }
        
        for item in allMetadata.filter([.commonIdentifierLastModifiedDate]) {
            if let date = try? await item.load(.dateValue) {
                metadata.modified = date
                break
            }
        }
        
        for item in allMetadata.filter([.commonIdentifierCreationDate, .id3MetadataDate]) {
            if let date = try? await item.load(.dateValue) {
                metadata.published = date
                break
            }
        }
        
        metadata.languages = await allStrings(for: [.commonIdentifierLanguage, .id3MetadataLanguage])
        metadata.subjects = await allStrings(for: [.commonIdentifierSubject]).map { Subject(name: $0) }
        
        metadata.authors = await allStrings(for: [
            .commonIdentifierAuthor, .iTunesMetadataAuthor, .commonIdentifierArtist,
            .id3MetadataOriginalArtist, .iTunesMetadataArtist, .iTunesMetadataOriginalArtist
        ]).map { Contributor(name: $0) }
        
        metadata.illustrators = await allStrings(for: [.iTunesMetadataAlbumArtist]).map { Contributor(name: $0) }
        metadata.contributors = await allStrings(for: [.commonIdentifierContributor]).map { Contributor(name: $0) }
        metadata.publishers = await allStrings(for: [.commonIdentifierPublisher, .id3MetadataPublisher, .iTunesMetadataPublisher]).map { Contributor(name: $0) }
        metadata.narrators = await allStrings(for: [.id3MetadataComposer, .iTunesMetadataComposer]).map { Contributor(name: $0) }
        
        if let description = await firstString(for: [.commonIdentifierDescription, .iTunesMetadataDescription]) {
            metadata.description = description
        }
        
        metadata.duration = totalDuration
        manifest.metadata = metadata
        
        // 2. Extract Cover Image
        var cover: PlatformImage? = nil
        for item in allMetadata.filter([.commonIdentifierArtwork, .id3MetadataAttachedPicture, .iTunesMetadataCoverArt]) {
            if let data = try? await item.load(.dataValue), let image = PlatformImage(data: data) {
                cover = image
                break
            }
        }
        
        return .init(manifest: manifest, cover: cover)
    }
    #else
    public func augment(_ manifest: Manifest, using container: Container) async -> AudioPublicationAugmentedManifest {
        let avAssets = manifest.readingOrder.map { link in
            container[link.url()]?.sourceURL?.fileURL
                .map { AVURLAsset(url: $0.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]) }
        }
        var manifest = manifest
        manifest.readingOrder = zip(manifest.readingOrder, avAssets).map { link, avAsset in
            guard let avAsset = avAsset else { return link }
            var link = link
            link.title = avAsset.metadata.filter([.commonIdentifierTitle]).first(where: { $0.stringValue })
            link.duration = avAsset.duration.seconds
            return link
        }
        let avMetadata = avAssets.compactMap { $0?.metadata }.reduce([], +)
        var metadata = manifest.metadata
        metadata.localizedTitle = avMetadata.filter([.commonIdentifierTitle, .id3MetadataAlbumTitle]).first(where: { $0.stringValue })?.localizedString ?? manifest.metadata.localizedTitle
        metadata.localizedSubtitle = avMetadata.filter([.id3MetadataSubTitle, .iTunesMetadataTrackSubTitle]).first(where: { $0.stringValue })?.localizedString
        metadata.modified = avMetadata.filter([.commonIdentifierLastModifiedDate]).first(where: { $0.dateValue })
        metadata.published = avMetadata.filter([.commonIdentifierCreationDate, .id3MetadataDate]).first(where: { $0.dateValue })
        metadata.languages = avMetadata.filter([.commonIdentifierLanguage, .id3MetadataLanguage]).compactMap(\.stringValue).removingDuplicates()
        metadata.subjects = avMetadata.filter([.commonIdentifierSubject]).compactMap(\.stringValue).removingDuplicates().map { Subject(name: $0) }
        // Authors are often stored as "artist":
        // - https://www.audiobookshelf.org/docs/#book-audio-metadata
        // - https://github.com/denizsafak/abogen#about-metadata-tags
        metadata.authors = avMetadata.filter(
            [
                .commonIdentifierAuthor,
                .iTunesMetadataAuthor,
                .commonIdentifierArtist,
                .id3MetadataOriginalArtist,
                .iTunesMetadataArtist,
                .iTunesMetadataOriginalArtist,
            ]
        ).compactMap(\.stringValue).removingDuplicates().map { Contributor(name: $0) }
        metadata.illustrators = avMetadata.filter([.iTunesMetadataAlbumArtist]).compactMap(\.stringValue).removingDuplicates().map { Contributor(name: $0) }
        metadata.contributors = avMetadata.filter([.commonIdentifierContributor]).compactMap(\.stringValue).removingDuplicates().map { Contributor(name: $0) }
        metadata.publishers = avMetadata.filter([.commonIdentifierPublisher, .id3MetadataPublisher, .iTunesMetadataPublisher]).compactMap(\.stringValue).removingDuplicates().map { Contributor(name: $0) }
        // Narrators are often stored as "composer":
        // - https://www.audiobookshelf.org/docs/#book-audio-metadata
        // - https://github.com/denizsafak/abogen#about-metadata-tags
        metadata.narrators = avMetadata.filter([.id3MetadataComposer, .iTunesMetadataComposer]).compactMap(\.stringValue).removingDuplicates().map { Contributor(name: $0) }
        metadata.description = avMetadata.filter([.commonIdentifierDescription, .iTunesMetadataDescription]).first?.stringValue
        metadata.duration = avAssets.reduce(0) { duration, avAsset in
            guard let duration = duration, let avAsset = avAsset else { return nil }
            return duration + avAsset.duration.seconds
        }

        manifest.metadata = metadata
        let cover = avMetadata.filter([.commonIdentifierArtwork, .id3MetadataAttachedPicture, .iTunesMetadataCoverArt]).first(where: { $0.dataValue.flatMap(PlatformImage.init(data:)) })
        return .init(manifest: manifest, cover: cover)
    }
    #endif
}

private extension [AVMetadataItem] {
    func filter(_ identifiers: [AVMetadataIdentifier]) -> [AVMetadataItem] {
        identifiers.flatMap { AVMetadataItem.metadataItems(from: self, filteredByIdentifier: $0) }
    }
}
