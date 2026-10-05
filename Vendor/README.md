# Vendor

Copies of three Swift packages I share with my other projects. They live here so
that NoDraw builds from a clean clone instead of needing a sibling checkout.

| Package | Product | What it does |
|---|---|---|
| `macos-native-subject-isolation` | `SubjectIsolation` | Vision segmentation, contour tracing, subject glow rendering |
| `macos-native-photo-pipeline` | `PhotoPipeline` | Image analysis modules feeding a local embedding search index |
| `DataTable` | `DataTable` | The SwiftUI table used by the browse view |

These are snapshots, not submodules. Edits made here do not flow back to my
working copies, and updates land by recopying.

None of the three carried a license file of its own. As copies inside this
repository they are covered by the MIT license at the repository root.

`PhotoPipeline` loads private Apple frameworks with `dlopen` and cannot run in a
sandbox. Its `docs/` directory describes that framework surface.
