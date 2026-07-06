import Foundation
import Supabase
import UIKit

/// Loads an animal's display photo from the private `muzzles` bucket.
/// Prefers the full-body shot (`{owner}/{animal}/full/`), falls back to a
/// muzzle crop (`.../muzzle/`), and returns nil on any failure (callers show
/// the initials avatar). Caches decoded images in memory (NSCache) and raw
/// JPEG bytes on disk (Caches/AnimalPhotos, keyed by object path).
final class AnimalPhotoLoader {
    static let shared = AnimalPhotoLoader()

    private let client: SupabaseClient
    private let memoryCache = NSCache<NSString, UIImage>()
    private let diskDirectory: URL

    init(client: SupabaseClient = SupabaseClientProvider.shared) {
        self.client = client
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDirectory = caches.appendingPathComponent("AnimalPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    /// Returns the animal's display photo, or nil so the caller falls back to the
    /// initials avatar. Uses the chosen `profilePath` when set, otherwise the
    /// first stored image. Never throws.
    func photo(ownerID: String, animalID: String, profilePath: String? = nil) async -> UIImage? {
        let cacheKey = "\(ownerID.lowercased())/\(animalID.lowercased())" as NSString
        if let cached = memoryCache.object(forKey: cacheKey) {
            return cached
        }

        let objectPath: String
        if let profilePath, !profilePath.isEmpty {
            objectPath = profilePath
        } else if let first = await firstObjectPath(ownerID: ownerID, animalID: animalID) {
            objectPath = first
        } else {
            return nil
        }

        if let image = diskImage(for: objectPath) {
            memoryCache.setObject(image, forKey: cacheKey)
            return image
        }

        guard let data = try? await client.storage.from("muzzles").download(path: objectPath),
              let image = UIImage(data: data) else {
            return nil
        }
        memoryCache.setObject(image, forKey: cacheKey)
        try? data.write(to: diskURL(for: objectPath), options: .atomic)
        return image
    }

    /// Object paths were written by the embedder as `{jwt-sub}/{form animal_id}/…`:
    /// the owner segment is always lowercase (JWT sub) but the animal segment
    /// keeps the case the client sent (UUID.uuidString is uppercase), so probe
    /// both. `full/` of any casing beats `muzzle/`.
    private func firstObjectPath(ownerID: String, animalID: String) async -> String? {
        let owner = ownerID.lowercased()
        var animalSegments = [animalID]
        if animalID.lowercased() != animalID {
            animalSegments.append(animalID.lowercased())
        }
        for kind in ["full", "muzzle"] {
            for animal in animalSegments {
                let prefix = "\(owner)/\(animal)/\(kind)"
                guard let objects = try? await client.storage.from("muzzles").list(path: prefix),
                      let first = objects.first else {
                    continue
                }
                return "\(prefix)/\(first.name)"
            }
        }
        return nil
    }

    /// The animal's quality-of-life photos (profile + cow body shots) for the
    /// detail gallery. Muzzle crops are program data, not user-facing, so they're
    /// excluded — only the `full/` folder is listed. Empty on any failure.
    func galleryPhotoPaths(ownerID: String, animalID: String) async -> [String] {
        let owner = ownerID.lowercased()
        var animalSegments = [animalID]
        if animalID.lowercased() != animalID {
            animalSegments.append(animalID.lowercased())
        }
        for animal in animalSegments {
            let prefix = "\(owner)/\(animal)/full"
            guard let objects = try? await client.storage.from("muzzles").list(path: prefix) else {
                continue
            }
            let paths = objects.filter { $0.name.hasSuffix(".jpg") }.map { "\(prefix)/\($0.name)" }
            // The first casing that actually has files wins — don't also append the
            // other casing, which on a case-insensitive backend would double them.
            if !paths.isEmpty { return paths }
        }
        return []
    }

    /// Drops the cached avatar for an animal so the next load reflects a newly
    /// chosen profile photo.
    func invalidateAvatar(ownerID: String, animalID: String) {
        let key = "\(ownerID.lowercased())/\(animalID.lowercased())" as NSString
        memoryCache.removeObject(forKey: key)
    }

    /// Downloads (and caches) a single image by its storage object path. Used by
    /// the detail gallery; returns nil on any failure.
    func image(at objectPath: String) async -> UIImage? {
        let key = objectPath as NSString
        if let cached = memoryCache.object(forKey: key) { return cached }
        if let image = diskImage(for: objectPath) {
            memoryCache.setObject(image, forKey: key)
            return image
        }
        guard let data = try? await client.storage.from("muzzles").download(path: objectPath),
              let image = UIImage(data: data) else {
            return nil
        }
        memoryCache.setObject(image, forKey: key)
        try? data.write(to: diskURL(for: objectPath), options: .atomic)
        return image
    }

    private func diskURL(for objectPath: String) -> URL {
        // "/" is not valid in a file name; flatten the object path.
        let name = objectPath.replacingOccurrences(of: "/", with: "_")
        return diskDirectory.appendingPathComponent(name)
    }

    private func diskImage(for objectPath: String) -> UIImage? {
        guard let data = try? Data(contentsOf: diskURL(for: objectPath)) else { return nil }
        return UIImage(data: data)
    }
}
