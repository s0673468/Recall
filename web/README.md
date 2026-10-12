# Recall web client

Use the existing bookmarked Recall Hub client for laptop and web review. Its
canonical private source repository is [s0673468/recall-hub](https://github.com/s0673468/recall-hub).
The deployed Hub URL has not been verified here; use the existing client bookmark.

The built-in Flutter PWA in this directory is retired from build and publication.
Its legacy source remains preserved. CI and local test plans no longer build or
stamp this bundle, and the historical Pages publisher is disabled for both main
pushes and manual dispatches.

Stopping these builds does not prove that the old hosted site is gone, that an
installed browser worker has stopped serving it, or that old pending reviews have
synced. This source change does not clear caches, localStorage or IndexedDB, or
unregister service workers. Unsent reviews in the old client must be preserved and
resolved before abandoning that client. No old-outbox export, transfer or
zero-pending proof, or live Hub acceptance, is established by this retirement.
