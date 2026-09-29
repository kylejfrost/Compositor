# Integration and proposed PR sequence for Compositor 1.4

The integration branch `feat/psd-mcp-v1.4` is based on the exact upstream `v1.4` tag (`d04f159`). It carries the work from `feat/mcp-server` (`26b114b`) as an integrated tree. The original branch is preserved. This document proposes review slices; the integration branch itself is not a suitably sized pull request.

| PR | Feature set | Depends on | Review and acceptance focus |
| --- | --- | --- | --- |
| 1 | Photoshop import and project fidelity: raw PSD blocks, editable text, effects, shapes, smart objects, masks, locks, fill opacity, format 10 records under the current format 11 manifest | `v1.4` | Synthetic PSD import and `.comp` round trips; malformed and oversized data; Image Size, Canvas Size and Crop; 1.4 mixed-font editing and mask behavior |
| 2 | Layered PSD writer and Save As: loss reporting, preserved blocks, text, effects, vector and adjustment writers, embedded smart objects, external verification scripts | PR 1 | Writer round trips; psd-tools parsing; Photoshop open and re-typeset comparison on copied, approved fixtures |
| 3 | Profile adjustments: parser, profile library, renderer, project sidecars and editing | PR 1 | Reference fixtures, saved/reopened render equality, document limits, GPU canvas fallback while a profile table bakes |
| 4 | MCP foundation: local server, access token, bridge, request isolation, file access, document and layer tools | PR 1 | Auth and transport refusals, temporary Agent roots and port 0 in tests, one undo step per edit, UI/tool guard parity |
| 5 | MCP editing breadth: selection, paint, text, shapes, effects, smart objects, profiles, PSD save and batches | PRs 2–4 | Tool schemas and docs, positive and negative tool calls, rollback, PSD output, app and MCP project saves with Quick Look previews |
| 6 | Skills, evals, logging, install/package scripts and user documentation | PR 5 | Script tests, generated tool atlas, install/uninstall behavior, no stale version or release claims |

Each PR branch should start from the preceding green branch, carry only its own tests and documentation, and be built with its own DerivedData. Once the stack is green, the PRs can target the preceding branch for review, then be retargeted to upstream `main` in sequence. The proposed boundaries may need a small shared foundation commit where import, profile, and MCP code use the same document model.

## 1.4 compatibility decisions

- Keep format 11 and its `fontRuns` validation. Photoshop data remains legal from format 10.
- Preserve 1.4's mask import and high resolution adjustment rendering while keeping PSD mask data and the profile rendering policy.
- Keep 1.4's Quick Look preview in app saves and write it in MCP project saves too.
- Fall back to the CPU canvas for Profile adjustments until the GPU can use the profile lookup without baking it on the main thread.
- Write Compositor's edited font and color runs into Photoshop EngineData; untouched imported `TySh` blocks still go back byte for byte.

## Verification boundary

The automated suites and psd-tools cover file structure, import, saved project state, rendered pixels and refusal paths. A real Photoshop open and re-typeset run remains a separate acceptance check; the harness and its tolerances are in `docs/psd-export.md`. Do not claim universal Photoshop feature parity: CMYK and 16/32-bit files, unsupported adjustment and fill layers, and imported text with mixed sizes or other styles after editing remain documented limitations. A synthetic mixed-font PSD parsed without warnings in psd-tools, but the Photoshop harness could not pass its System Events preflight in this environment.
