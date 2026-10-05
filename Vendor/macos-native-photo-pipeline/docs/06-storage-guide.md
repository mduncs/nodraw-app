# Storage Guide

How PhotoPipeline stores data, manages silos, and handles index lifecycle.

---

## Silo Layout

Each app gets its own isolated storage directory. No shared state with Photos.app or other apps.

```
{storePath}/
├── embeddings/              ← CLIP vector embeddings
│   └── meta/
│       ├── img-001.emb      (raw float32 embedding data)
│       ├── img-002.emb
│       └── ...
├── gallery/                 ← Face identity database
│   └── faces/
│       ├── img-001_identity-A.json
│       └── ...
├── classifications/         ← Analysis results cache
│   ├── scene/
│   │   ├── img-001.json     (SceneResult as JSON)
│   │   └── ...
│   ├── object/
│   │   ├── img-001.json     (Recognition[] as JSON)
│   │   └── ...
│   ├── text/
│   │   ├── img-001.json     (TextObservation[] as JSON)
│   │   └── ...
│   ├── junk/
│   │   ├── img-001.json     (JunkResult as JSON)
│   │   └── ...
│   └── curation/
│       ├── img-001.json     (CurationResult as JSON)
│       └── ...
├── text/                    ← Reserved for full-text search index
└── config.json              ← IndexConfiguration (Codable)
```

## Storage Sizes

Approximate per-asset storage:

| Data Type | Per Asset | Notes |
|-----------|-----------|-------|
| Embedding (fallback) | ~2 KB | Float32 vector (512-dim × 4 bytes) |
| Embedding (IVF) | ~0.5 KB | Compressed via MADVectorDatabase |
| Scene classification | ~500 B | JSON with labels + scores |
| Object recognition | ~800 B | JSON with names + domains + bounding boxes |
| Text observations | ~200 B | JSON per text region |
| Face observation | ~300 B | JSON with bounding box + identity ID |
| Junk classification | ~200 B | JSON with confidence + source |
| Curation score | ~300 B | JSON with score + components |
| **Total per asset** | **~3-6 KB** | Varies by content |

For 10,000 images: ~20-50 MB total storage.

## Creating a Store

### Default location

```swift
// ~/Library/Application Support/{bundleID}/PhotoPipeline/
let store = try PipelineStore.defaultStore()
```

### Custom location

```swift
let store = try PipelineStore(rootPath: URL(fileURLWithPath: "/tmp/my-index"))
```

### Via SearchIndex

```swift
// SearchIndex creates a PipelineStore internally
let index = try SearchIndex(configuration: .full, storePath: myURL)
```

## Configuration Persistence

Configuration is saved as `config.json` in the store root:

```swift
// Save
try store.saveConfig(IndexConfiguration.full)

// Load (nil if no config saved)
if let config = store.loadConfig() {
    print("Loaded config: embeddings=\(config.enableEmbeddingSearch)")
}
```

SearchIndex automatically saves its configuration on init, so you can recover the config after a restart.

## Monitoring

```swift
let store = try PipelineStore(rootPath: storePath)

// Total size on disk
let bytes = try store.totalSizeBytes()
print("\(bytes / 1024) KB")

// Number of indexed assets
let count = try store.indexedAssetCount()
print("\(count) assets")

// Full stats via SearchIndex
let index = try SearchIndex(configuration: .full, storePath: storePath)
let stats = try index.stats()
print("""
Assets: \(stats.totalAssets)
Embeddings: \(stats.embeddingCount)
Store size: \(stats.storeSizeBytes / 1024 / 1024) MB
""")
```

## Resetting

Nuclear option — wipes all stored data and recreates the directory structure:

```swift
try store.reset()
// All data gone. Directory structure recreated.
```

## Index Rebuild

After bulk inserts, rebuild the IVF index for optimal search quality:

```swift
let search = try EmbeddingSearch(storePath: embeddingsURL)

// Bulk insert
for (id, image) in batch {
    try await search.index(image: image, assetID: id)
}

// Rebuild compacts the IVF index
try await search.rebuild()
```

The IVF index uses a delta store for incremental updates. `rebuild()` compacts the delta store into the main index, which produces better partition assignments and faster searches.

## Removing Assets

```swift
// Remove from a specific module
let search = try EmbeddingSearch(storePath: embeddingsURL)
try search.remove(assetID: "img-001")

// Remove from all modules via SearchIndex
let index = try SearchIndex(configuration: .full, storePath: storePath)
try await index.remove(assetID: "img-001")
```

## Backup & Migration

The silo is a plain directory of JSON files and binary blobs. To backup:

```bash
cp -r /path/to/store /path/to/backup
```

To migrate to a new location:

```bash
mv /old/store /new/store
```

Then point your code to the new path. The library doesn't store absolute paths internally.

## Embedding Version Migration

When upgrading from an older embedding version (e.g., MD5 → MD7v2), you need to re-index all assets because embedding vectors from different versions are incompatible:

```swift
// 1. Create a new store with the new version
let newConfig = IndexConfiguration(embeddingVersion: .md7v2)
let newIndex = try SearchIndex(configuration: newConfig, storePath: newStorePath)

// 2. Re-index all images
let manager = IndexManager(searchIndex: newIndex)
let report = try await manager.indexDirectory(imagesDir)

// 3. Optionally, delete the old store
try FileManager.default.removeItem(at: oldStorePath)
```

Apple's internal system handles this via `SceneImageEmbeddingMigrationTimestamp` — but since we own the silo, a clean re-index is simpler.

## Thread Safety

All storage operations are thread-safe:

- `PipelineStore` methods are synchronous and safe from any thread
- `VectorStore` has internal locking for concurrent upsert/search
- `MetadataStore` is file-based with per-operation atomicity
- Concurrent reads are safe; concurrent writes to the same asset ID are last-writer-wins

## Apple's Native Storage (for reference)

When private frameworks are available, the library creates these native storage structures:

| Storage | Apple Class | Our Fallback |
|---------|-------------|--------------|
| Vector database | MADVectorDatabase (IVF + delta store) | VectorStore (flat file + brute-force) |
| Face gallery | VUGallery (CoreData + IVF) | JSON files |
| Metadata cache | Core Data (PhotosDataStore.momd) | JSON files per asset |

The fallback storage is adequate for <10K assets. For larger collections, the private framework path is strongly preferred because MADVectorDatabase's IVF index is orders of magnitude faster than brute-force search.
