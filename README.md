# Storify (`storify.koplugin`)

> **In-App Package Manager & Discovery Engine for KOReader**

Storify is a modular, test-driven package manager for KOReader on e-ink devices. It allows users to discover, install, update, and manage community plugins and user patches directly from their e-reader.

---

## Features

- **In-App Discovery**: Browse community plugins (`koreader-plugin`) and user patches (`koreader-user-patch`) via the community-maintained `awesome.koreader` catalog index — one fast request instead of live GitHub API crawling, refreshed on demand.
- **Disk Discovery & Auto-Linking**: Automatically detects side-loaded plugins on disk and matches them against GitHub repositories. An explicit "Match with repo" retry re-attempts linking for anything the passive scan couldn't resolve on its own.
- **Live Update Checking**: On-demand GitHub release checks surface real update-available status per plugin, with a one-tap filter to show only what needs attention.
- **Patch Install & Management**: Browse patch-collection repositories, drill into their individual `.lua` files, and install, update, or delete them directly in KOReader's patches directory — fully tracked, alongside plugin management.
- **Resilient SQLite Storage**: Cached metadata stored in SQLite WAL mode with automatic corruption detection and quarantine recovery.
- **Safe Atomic Deployment**: Zip Slip and symlink-escape defenses (including post-extraction containment for the shell `unzip`/`tar` fallback), `<target>.new` staging, byte-verified user config preservation, and automatic `.bak` rollback on failure.
- **E-Ink Optimized UI**: Full D-pad, page-key, and touch navigation powered by `FocusManager`, with rate-limited repaints and non-modal progress dialogs.
- **Download Proxy / Mirror Support**: Built-in mirror presets and custom URL proxy routing for restricted network environments.
- **Multi-Language Support**: Complete localization across English, German, Spanish, French, Hungarian, Portuguese (Brazil), Turkish, and Simplified Chinese.

---

## Architecture

Storify follows a clean **Layered Domain-Driven Architecture**:

```
storify.koplugin/
├── core/                               # Pure Domain Layer (Zero UI dependencies)
│   ├── storify_version.lua            # SemVer, date versioning & tag comparisons
│   ├── storify_manifest.lua           # Sandboxed _meta.lua parser & descriptors
│   ├── storify_matcher.lua            # Local-to-remote reconciliation & disk scanner
│   └── storify_installer.lua          # Zip Slip defense, staging & atomic swap
│
├── data/                               # Persistence Layer
│   ├── storify_cache.lua              # SQLite WAL storage & corruption recovery
│   ├── storify_installs.lua           # Install tracking & generation counter
│   ├── storify_settings.lua           # LuaSettings singleton provider
│   └── storify_plugin_paths.lua       # Filesystem lookup & destination resolver
│
├── net/                                # Transport & Network Layer
│   ├── storify_net.lua                # Timeout-safe socket transport wrapper
│   ├── storify_net_github.lua         # GitHub REST API client & redirect guard
│   ├── storify_crawler.lua            # awesome.koreader catalog fetch & patch tree indexing
│   ├── storify_mirror.lua             # Download proxy & mirror transformer
│   └── storify_repo_content.lua       # README downloader & markdown viewer
│
├── ui/                                 # Presentation Layer
│   ├── storify_widgets.lua            # List items, status badges, pagination bar
│   ├── storify_dialogs.lua            # Details modals, mirror settings, manual linker
│   ├── storify_browser_dialog.lua     # Full-screen catalog browser (FocusManager)
│   ├── storify_updates_dialog.lua     # Full-screen updates management dialog
│   └── storify_progress.lua           # E-ink non-modal progress bar
│
├── l10n/                               # Localization Layer (8 language catalogs)
├── main.lua                            # Plugin Lifecycle Orchestrator (wires UI to core/data/net)
└── tests/                              # Standalone Headless Test Suite (15 suites)
```

---

## Running Automated Tests

All tests run headlessly under standard `luajit` without requiring a graphical KOReader instance:

```bash
luajit tests/test_runner.lua
```

---

## License

This project is licensed under the GNU General Public License v3.0 — see the [LICENSE](LICENSE) file for details.
