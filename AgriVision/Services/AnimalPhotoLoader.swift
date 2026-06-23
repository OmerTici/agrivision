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

    /// Returns the animal's photo, or nil so the caller falls back to the
    /// initials avatar. Never throws.
    func photo(ownerID: String, animalID: String) async -> UIImage? {
        let cacheKey = "\(ownerID.lowercased())/\(animalID.lowercased())" as NSString
        if let cached = memoryCache.object(forKey: cacheKey) {
            return cached
        }

        guard let objectPath = await firstObjectPath(ownerID: ownerID, animalID: animalID) else {
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

    /// All enrolled image object paths for an animal — full-body shots first,
    /// then muzzle crops — for the detail gallery. Empty on any failure.
    func allPhotoPaths(ownerID: String, animalID: String) async -> [String] {
        let owner = ownerID.lowercased()
        var animalSegments = [animalID]
        if animalID.lowercased() != animalID {
            animalSegments.append(animalID.lowercased())
        }
        var paths: [String] = []
        for kind in ["full", "muzzle"] {
            for animal in animalSegments {
                let prefix = "\(owner)/\(animal)/\(kind)"
                guard let objects = try? await client.storage.from("muzzles").list(path: prefix) else {
                    continue
                }
                for object in objects where object.name.hasSuffix(".jpg") {
                    paths.append("\(prefix)/\(object.name)")
                }
            }
        }
        return paths
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
