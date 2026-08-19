# Architecture Decisions (ADRs)

<!--
Record format - one `## ` heading per decision, newest appended last:
-->

## ADR-001: Layered Domain-Driven Architecture
- **Context**: An early single-file monolith exceeded 195 top-level locals, violated LuaJIT local budgets, was untestable without a full graphic KOReader build, and tightly coupled networking, SQLite transactions, and UI.
- **Decision**: The plugin is deconstructed into 5 decoupled layers: `core/` (pure domain & business logic), `data/` (SQLite WAL persistence & settings), `net/` (safe transport, GitHub client, and catalog crawler), `ui/` (FocusManager widgets & dialogs), and `l10n/` (localization). `main.lua` is a thin orchestrator wiring UI events to these layers.
- **Consequences**: Enables 100% headless mock testing (`luajit tests/test_runner.lua`, 15 suites) without a graphical KOReader build.

## ADR-002: Side-Loaded Plugin Disk Discovery & Auto-Linking
- **Context**: Plugins manually placed on device storage or cloned via USB/Git are invisible to a catalog-only package manager and can't receive update checks.
- **Decision**: Automated disk scanning across `PluginPaths.getLookupPaths()`, sniffing versions from `_meta.lua` or regex matching in `main.lua`, and reconciling against the SQLite catalog with automatic upsert into `data/storify_installs.lua`'s store. An explicit "Match with repo" retry bypasses the passive scan's staleness guard for records it couldn't resolve.
- **Consequences**: Users can update and manage side-loaded plugins with one click, or manually link unlisted plugins to a GitHub repository.

## ADR-003: awesome.koreader Catalog Integration & On-Demand Patch Tree Indexing
- **Context**: Live GitHub API crawling (dual topic/name queries, fork filtering, recursive Git tree indexing) was slow and rate-limit-exposed for routine browsing.
- **Decision**: `net/storify_crawler.lua` fetches the community-maintained `fusuyfusuy/awesome.koreader` catalog index as the fast path (one HTTP request for ~1000 plugins + ~100 patch collections), falling back to the original dual-branch GitHub search crawler only if that fetch fails. Individual patch files within a patch-collection repo are indexed lazily via `Crawler.fetchPatchFileTree`, the first time a user drills into that repo — not eagerly for the whole catalog, which would reintroduce the crawling cost this integration removed.
- **Consequences**: Catalog refresh is a single fast request instead of dozens of paginated searches; patch file browsing has no up-front indexing cost across the full catalog.

## ADR-004: Side-by-Side Coexistence & Storage Isolation
- **Context**: Users installing Storify alongside other KOReader package-manager plugins risk database locking collisions and overwritten configuration files.
- **Decision**: Storify's settings and SQLite catalog live under isolated, Storify-specific paths, never shared with another plugin's storage.
- **Consequences**: Multiple such plugins can run concurrently without clashing on locks or settings.

## ADR-005: Patches Install as Single Files, Not Zip Packages
- **Context**: KOReader's real patch loader (`userpatch.lua`) runs every `.lua` file directly out of a flat `patches/` directory, alphanatural-sorted and filtered by a `<priority>-` filename prefix — a fundamentally different install target than a `.koplugin` folder in `plugins/`.
- **Decision**: `Storify:handleInstallPatchFile` downloads a single patch file straight to `DataStorage:getPatchesDir()` via `Net.requestToFile`, never through `Installer.installPackage`'s zip-extraction path. Install/update/delete for patches are tracked separately from plugins (`Installs.upsertPatch`/`getPatch`/`removePatch`), keyed by filename.
- **Consequences**: Browse User Patches drills from a patch-collection repo into its individual files before any install action, matching how KOReader actually consumes them; plugin and patch installs share no code path that would apply the wrong mechanism to either.
