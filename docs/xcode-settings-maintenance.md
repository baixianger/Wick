# Xcode "Update to Recommended Settings" — maintenance procedure

**Why this doc exists:** every time Apple ships a new Xcode major version,
its project template adds / changes a few build-settings keys. Opening
the project in the new Xcode produces a yellow warning ribbon
("This project should be updated to recommended settings") that you
can't dismiss permanently from the UI — clicking *Update* writes the
new keys into `.pbxproj`, but the next `xcodegen generate` wipes them.

The fix is to set those keys in **`project.yml`** so xcodegen bakes them
into every regenerated project file.

This procedure tells you which file to diff, where xcodegen's own
defaults sit, and how to verify the result without opening Xcode at all.

---

## The two source-of-truth files

```
# What Xcode wants
/Applications/Xcode.app/Contents/Developer/Library/Xcode/Templates/
  Project Templates/Base/Base_ProjectSettings.xctemplate/TemplateInfo.plist

# What xcodegen ships as defaults
$(brew --prefix xcodegen)/share/xcodegen/SettingPresets/
  ├── base.yml                    # general — most CLANG_/GCC_/MTL_ flags
  ├── Configs/{debug,release}.yml # per-configuration
  ├── Platforms/{macOS,iOS,…}.yml # SDK / runpath
  └── Products/{application,tool,framework}.yml
```

**The delta between these two is what `project.yml` has to patch.**

---

## Diff routine (run after each Xcode major-version bump)

```bash
# 1. Pretty-print what Xcode wants right now
plutil -p "/Applications/Xcode.app/Contents/Developer/Library/Xcode/Templates/Project Templates/Base/Base_ProjectSettings.xctemplate/TemplateInfo.plist"

# 2. Pretty-print what xcodegen ships (catch the version drift)
cat $(brew --prefix xcodegen)/share/xcodegen/SettingPresets/base.yml
cat $(brew --prefix xcodegen)/share/xcodegen/SettingPresets/Configs/debug.yml
cat $(brew --prefix xcodegen)/share/xcodegen/SettingPresets/Configs/release.yml

# 3. For each Xcode key NOT in xcodegen's preset (or with a stale
#    value), patch project.yml's `settings.base`.

# 4. Regenerate + verify the values surfaced on every target
xcodegen generate
for target in Wick WickMCP; do
  echo "=== $target ==="
  xcodebuild -project Wick.xcodeproj -target "$target" \
    -configuration Debug -showBuildSettings 2>/dev/null \
    | grep -E "^\s*(CLANG_CXX_LANGUAGE_STANDARD|GCC_C_LANGUAGE_STANDARD|SWIFT_APPROACHABLE_CONCURRENCY|SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY|LOCALIZATION_PREFERS_STRING_CATALOGS|SWIFT_VERSION)\s*=" \
    | sort
done
```

The grep list isn't exhaustive — add the new keys you found in step 1.

---

## Current state (recorded 2026-05-28, Xcode 26.5, xcodegen 2.45.3)

xcodegen's `base.yml` is missing or stale on these keys vs Xcode 26.5's
template. They're patched at the top of `project.yml` `settings.base`:

| Key | Xcodegen ships | Xcode 26.5 wants | In `project.yml`? |
|---|---|---|---|
| `CLANG_CXX_LANGUAGE_STANDARD` | `gnu++14` | `gnu++20` | ✅ overrides at base |
| `GCC_C_LANGUAGE_STANDARD` | `gnu11` | `gnu17` | ✅ overrides at base |
| `SWIFT_APPROACHABLE_CONCURRENCY` | _not set_ | `YES` (target-level) | ✅ at project base (inherited) |
| `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY` | _not set_ | `YES` (target-level) | ✅ at project base (inherited) |
| `LOCALIZATION_PREFERS_STRING_CATALOGS` | _not set_ | `YES` (project) | ✅ |
| `ENABLE_USER_SCRIPT_SANDBOXING` | _not set_ | `YES` (project) | ✅ |
| `ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS` | _not set_ | `YES` (project) | ✅ |

xcodegen DOES cover (you don't need to patch these):

- Every `CLANG_WARN_*` flag the template requires
- Every `GCC_WARN_*` flag the template requires
- `MTL_FAST_MATH`, `MTL_ENABLE_DEBUG_INFO`
- `ENABLE_STRICT_OBJC_MSGSEND`, `COPY_PHASE_STRIP`
- Debug: `ENABLE_TESTABILITY`, `ONLY_ACTIVE_ARCH`, `GCC_OPTIMIZATION_LEVEL=0`, `SWIFT_OPTIMIZATION_LEVEL=-Onone`, `SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG`
- Release: `ENABLE_NS_ASSERTIONS=NO`, `SWIFT_COMPILATION_MODE=wholemodule`, `SWIFT_OPTIMIZATION_LEVEL=-O`

---

## Why we put the Swift target keys at project-base

The Xcode template puts `SWIFT_APPROACHABLE_CONCURRENCY` and
`SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY` at the per-target
`SharedSettings` level. We instead put them at `settings.base` in
`project.yml` because:

1. Every Swift target needs the same value — duplicating per-target
   is just an opportunity to drift.
2. New targets (a future widget extension / a notification-content
   extension / a Quick Look preview) inherit them automatically.
3. xcodebuild verified the keys still surface correctly on each
   target's resolved settings (see verification grep above).

If a target ever needs to DISABLE one of these (unlikely), override
it inside that target's `settings.base`.

---

## What you should NOT need to touch

- Debug / Release per-configuration knobs — xcodegen covers them.
- Code-signing keys (`DEVELOPMENT_TEAM`, `CODE_SIGN_STYLE`) — set
  once at project base, inherited by every target.
- The `LD_RUNPATH_SEARCH_PATHS` / `SDKROOT` for macOS — covered by
  `SettingPresets/Platforms/macOS.yml`.

---

## When xcodegen itself updates

`xcodegen 2.x` ships its preset files inside the Homebrew bottle.
After `brew upgrade xcodegen`, re-run the diff routine — xcodegen
may have caught up on `gnu++20` / `gnu17` and your project.yml's
override becomes redundant (still harmless, but you can drop it).
