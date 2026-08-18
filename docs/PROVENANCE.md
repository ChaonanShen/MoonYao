# Provenance and license record

This file records external sources consulted or used by MoonYao Core. Update it
in the same pull request that introduces a dependency, copied artifact, or new
reference behavior.

| Item | Source and pinned revision/version | License | Use in MoonYao |
| --- | --- | --- | --- |
| Yao App Engine | [YaoApp/yao](https://github.com/YaoApp/yao), commit [`1eb2bb1ec89540bd50345b2b456eeb087bc21de0`](https://github.com/YaoApp/yao/tree/1eb2bb1ec89540bd50345b2b456eeb087bc21de0) | Modified Apache-2.0; see [upstream LICENSE](https://github.com/YaoApp/yao/blob/main/LICENSE) for additional commercial, branding, and verification terms | Conceptual reference only. MoonYao is independently designed from public behavior and documentation; no upstream source files are copied or translated. |
| MoonBit toolchain and core library | [moonbitlang/moon](https://github.com/moonbitlang/moon), [moonbitlang/core](https://github.com/moonbitlang/core) | Toolchain: AGPL-3.0; Core: Apache-2.0 | Build toolchain and standard library supplied by MoonBit; not bundled into this repository. |
| `actions/checkout@v5` | [actions/checkout](https://github.com/actions/checkout) | MIT | Checks out repository source in GitHub Actions. |
| `hustcer/setup-moonbit@v1.22` | [hustcer/setup-moonbit](https://github.com/hustcer/setup-moonbit/tree/v1.22) | MIT | Installs the MoonBit toolchain in GitHub Actions. |

## Rules

- Do not add externally sourced code, tests, documentation, images, or data
  without adding its URL, version or revision, license, purpose, and any
  modifications to this record.
- Do not copy Yao implementation files. A behavior-compatible design must be
  specified and implemented independently in MoonBit.
- Review upstream terms before introducing any code rather than relying only on
  a repository's displayed license badge.
