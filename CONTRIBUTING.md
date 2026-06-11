# Contributing

Thanks for your interest in contributing!

This is a fork of [scier/MetalSplatter](https://github.com/scier/MetalSplatter). The core rendering library (`MetalSplatter`, `PLYIO`, `SplatIO`) comes from upstream; the **SplatRecorder** macOS viewer/recorder app is maintained in this fork at [`Apps/SplatRecorder/`](Apps/SplatRecorder/).

## Scope

- **This fork welcomes contributions** to the SplatRecorder app, CI, documentation, and developer tooling.
- **Core renderer changes** should be proposed upstream at [scier/MetalSplatter](https://github.com/scier/MetalSplatter) unless they are specific to SplatRecorder integration.

## Development setup

```bash
git clone https://github.com/ruichaowang/MetalSplatterRecorder.git
cd MetalSplatterRecorder

# Root package (libraries + SplatConverter)
swift build
swift test

# SplatRecorder sub-package
cd Apps/SplatRecorder
swift build --product SplatRecorder
swift test
```

## Before submitting

- Run `swift test` at both the root and `Apps/SplatRecorder/` levels.
- If you modify Metal shaders (`.metal` files), regenerate `default.metallib`:
  ```bash
  ./script/build-metallib.sh
  ```

## Commit style

- Follow [Conventional Commits](https://www.conventionalcommits.org/).
- Keep commits focused — one logical change per commit.
