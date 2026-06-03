# Development Notes

## Recovery Merge Boundary

The working recovery line is based on build 104 display behavior and the
`recovery/build-104-display-good` branch.

Build 104 anchor:

- `347fb654dd7b7878f767aca922d95d31c5405e59` - Install scaling debs via local apt path

The following main-line range is retained as git history only. It had useful
intentions and ideas, but the combined execution regressed core display,
guest-session, and packaging behavior. Do not restore this range wholesale.
Use it only as reference material for isolated, reviewed, and tested ideas.

Idea-only main range:

- Range notation: `347fb654dd7b7878f767aca922d95d31c5405e59..332fabc12b7cbf616f2a0ab5d6d67a0c59cec508`
- First commit after build 104: `752a63ddb51d73544903cf424f14ba7b68ecd669`
- Last pre-recovery main commit: `332fabc12b7cbf616f2a0ab5d6d67a0c59cec508`

Commits in that idea-only range:

- `752a63ddb51d73544903cf424f14ba7b68ecd669` - Disable XFCE desktop icon label shadows
- `b7a4f15c591336c4b71e2cb2a7a83c0957c9e285` - Refactor XFCE appearance lifecycle
- `5096969bf939697da9823b0321fcac9e604ce129` - Rewrite GUI ensure lifecycle
- `1228d5f0de377a61ea24334faacb55844e62f238` - Remove monitor-specific no-idle default
- `1335623935a7af5387dc1d7094a55f798c36c787` - Add external display dashboard
- `b3518f9446660e75f32257b4a3b3508921a6f6d2` - Fix VM display session refresh
- `8c3d2a0925e75a2067113763f2581a3b6ed850d1` - Fix guest display GPU isolation
- `332fabc12b7cbf616f2a0ab5d6d67a0c59cec508` - Keep runtime and capture lifecycle app-owned

Recovery branch head before merging back to main:

- `53711c42cc798aa37e5ec969d8160fe9cb62b31b` - Update package verifier DriverKit label

The merge back to `main` is intentionally an ours-history merge: it records the
old `main` history as a parent while keeping the recovery tree as the code at
the new `main` tip.
