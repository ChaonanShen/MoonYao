# MoonYao Core

MoonYao Core is a MoonBit Native, declarative application engine inspired by
the public concepts of [Yao App Engine](https://github.com/YaoApp/yao). It is
an independent clean-room implementation: no Yao source code is copied or
translated.

The initial release will support a deliberately narrow vertical slice:

```text
JSON DSL -> application loader -> SQLite CRUD / Process -> sequential Flow -> HTTP API
```

## Status

The repository currently provides the M1 bootstrap: a Native MoonBit module, a
small executable, a unit test, and GitHub Actions checks. SQLite, JSON DSL,
Process dispatch, Flow, HTTP, and user-facing CLI subcommands are not yet
implemented.

## Scope

The first release targets MoonBit Native and SQLite only. It will use strict
JSON DSL files to declare models, sequential Flows, and fixed HTTP routes. It
will not implement Yao's JavaScript runtime, plugins, agents, UI, OpenAPI,
authentication, multi-tenancy, multi-database support, joins, or advanced Flow
control.

## Prerequisites

- MoonBit toolchain with Native target support.
- Git for obtaining the source.

Install MoonBit using the instructions for your platform in the
[official MoonBit documentation](https://docs.moonbitlang.com/en/latest/tutorial/tour.html).
The official macOS installer currently does not support Darwin x86_64; use a
supported MoonBit environment or rely on the repository's Linux CI until local
support is available.

## Build, test, and run

From the repository root:

```bash
moon fmt --check
moon check --target native
moon test --target native
moon build --target native
moon run src/cmd/main
```

The bootstrap executable prints:

```text
MoonYao Core bootstrap: Native runtime is ready.
```

## Planned delivery

1. Define structured errors and the single-JSON-value Process protocol.
2. Load and validate Model DSL without side effects.
3. Add SQLite schema creation and parameter-bound CRUD Processes.
4. Add input/result binding and sequential Flow execution.
5. Add HTTP routing, CLI commands, and an end-to-end Todo example.

Each meaningful item is tracked as a GitHub Issue and implemented through a
focused branch and pull request.

## License and provenance

MoonYao Core is licensed under [Apache License 2.0](LICENSE). Source and
license records, including the Yao reference and CI actions, are in
[docs/PROVENANCE.md](docs/PROVENANCE.md).

Yao's current repository license contains additional terms beyond standard
Apache-2.0. That license governs Yao; it does not change MoonYao's license.
Contributors must not copy Yao source code and must document every external
artifact before adding it.

## Contributing

Open an Issue with scope and acceptance checks before beginning a meaningful
change. Work in a focused branch, link the PR to the Issue, include tests, and
merge only after CI passes. Do not commit local notes, credentials, databases,
or build artifacts.
