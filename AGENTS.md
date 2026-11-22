# annotate

Fast full-screen screenshot annotation tool for X11 (replaces ksnip in i3).
Zig 0.15.2 (pinned in `mise.toml`). Run zig as `mise exec -- zig ...`.

## Dev loop

```sh
mise exec -- zig build              # build zig-out/bin/annotate
mise exec -- zig build test         # unit tests
mise exec -- zig build fmt          # format
```

## Rules

- Self-improvement: every hiccup (confusing error, slow or missing command,
  repeated manual step, missing doc) is a harness bug. Fix it in the repo in
  its own small commit.
- Commits: conventional (`feat:`, `fix:`, `docs:`, `test:`, `build:`, `chore:`,
  `perf:`, `refactor:`), atomic, green (`zig build test` passes).
