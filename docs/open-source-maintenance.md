# Open Source Maintenance

This document covers routine maintenance tasks for the MetalSplatterRecorder fork.

## Repository structure

```
origin   → ruichaowang/MetalSplatterRecorder (this fork)
upstream → scier/MetalSplatter              (upstream)
```

## Syncing with upstream

```bash
git fetch upstream
git checkout main
git merge upstream/main
# Resolve conflicts if any
git push origin main
```

After syncing, verify nothing is broken:

```bash
swift build
swift test
cd Apps/SplatRecorder
swift build --product SplatRecorder
swift test
```

## Rebuilding the Metal shader library

If `.metal` source files change (either from upstream or local edits), regenerate the compiled library:

```bash
./script/build-metallib.sh
```

The output is `MetalSplatter/Resources/default.metallib`, which is tracked in git to enable clean-checkout builds.

## Release checklist

1. Sync with upstream: `git fetch upstream && git merge upstream/main`
2. Regenerate metallib: `./script/build-metallib.sh`
3. Run full test suite (root + subpackage)
4. Test a real splat file: `cd Apps/SplatRecorder && swift run SplatRecorder --validate <file.ply> /tmp/check`
5. Tag: `git tag -a vX.Y.Z -m "Release vX.Y.Z" && git push origin vX.Y.Z`

## CI

GitHub Actions run on every push and PR:
- Root `swift build` + `swift test`
- `Apps/SplatRecorder` `swift build` + `swift test`

See `.github/workflows/ci.yml`.
