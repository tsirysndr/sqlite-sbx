# SQLite/libSQL sandbox test component

A PureScript native Wasm component for FluentCI **0.17.8**. The generated WIT
and help come from `src/Main.purs`; no Extism runtime is used.

```sh
fluentci run test all --help
fluentci run test all                        # Ubuntu x86_64, sudo and /dev/kvm
fluentci run test unit                       # any supported development host
fluentci run test e2e                        # installed bsdkrun, Docker and built dist/sqlite-sbx
```

`all` invokes the project's compiled PureScript CI runner (`src/Ci`). It
verifies the pinned bsdkrun release archive (default `v0.12.1`), installs its
bundled Linux libkrun libraries and gvproxy, and enables `/dev/kvm`. It leaves
engine creation and disk formatting to normal `sqlite-sbx start` and bsdkrun.
There is no host mkfs call, engine pre-start or custom file-limit adjustment.

The live suite checks that normal startup creates a native overlay engine on
ext4, then restarts the VM and checks its mount and data persistence. New engines
request a sparse 20 GiB image store; existing engines retain their configuration.
bsdkrun 0.12.1 provides the guest ext4 formatting fix on both macOS and Linux.
Diagnostics capture post-ZFS mounts, engine status and guest process limits.

It runs PureScript assertions and `bun test` for mocked CLI/CI checks, builds
the executable, then runs the opt-in Bun live suite. No Bash scripts are used.
The project's Node FFI only supplies process/filesystem/network primitives;
installation decisions, validations, assertions and cleanup are PureScript.
Missing virtualization/networking tools fail the job; tests are never skipped.

Use `--directory /path/to/sqlite-sbx` to select another checkout, or
`--bsdkrun-version vX.Y.Z` on `all` to deliberately change the runtime release.
The installer stores tools under the checkout's `.fluentci/tools/bsdkrun`.

The SDK is regenerated from the pinned CLI into ignored `.sdk/` by
`bootstrap.mjs`, then `build.mjs` uses the starter's locked npm/Spago tools to
compile the component. Commit the manifests, both lockfiles and authored
source. SDK copies, dependencies, generated WIT/metadata and Wasm output are
build artifacts. Run only one build/inspection command in this directory at
a time, as npm ci and componentization both replace generated files.

The live test uses a unique sandbox name and temporary configuration, removes
its own container and ZFS volume in `finally`, and preserves an already-running
engine. It stops an engine it started only when no other containers are
running. Logs and a machine-readable result go to `.fluentci/test-logs/`;
passwords and state files are excluded from diagnostics.

Command output streams to stderr to remain visible through FluentCI's stdout
capture. E2E prints redacted command lines and a heartbeat every 15 seconds.
Cold-image startup has a ten-minute limit; shorter per-command limits and
pipe-independent timeout handling keep failures bounded.
