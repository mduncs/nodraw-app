import Foundation
import CoreGraphics

/// Generic reference to an asset managed by the pipeline.
/// Decoupled from PHAsset — works with any image source.
public struct Asset: Sendable, Hashable, Identifiable {
    public let id: String
    public let sourceURL: URL?
    public let metadata: AssetMetadata?

    public init(id: String, sourceURL: URL? = nil, metadata: AssetMetadata? = nil) {
        self.id = id
        self.sourceURL = sourceURL
        self.metadata = metadata
    }
}

/// Metadata attached to an asset during indexing.
public struct AssetMetadata: Sendable, Hashable {
    public let dateCreated: Date?
    public let width: Int?
    public let height: Int?
    public let mediaType: MediaType
    public let location: Location?

    public init(
        dateCreated: Date? = nil,
        width: Int? = nil,
        height: Int? = nil,
        mediaType: MediaType = .image,
        location: Location? = nil
    ) {
        self.dateCreated = dateCreated
        self.width = width
        self.height = height
        self.mediaType = mediaType
        self.location = location
    }

    public enum MediaType: Int, Sendable, Hashable {
        case image = 0
        case video = 1
        case livePhoto = 2
    }

    public struct Location: Sendable, Hashable {
        public let latitude: Double
        public let longitude: Double

        public init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }
    }
}
