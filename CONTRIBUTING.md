# Contributing

Thanks for helping improve this project. Please follow the guidelines below to keep contributions consistent and reviewable.

## Getting started

1. Fork the repository and create a feature branch.
2. Make your changes with clear, focused commits.
3. Open a pull request describing the change and linking any related issue.

## Development

- Follow the existing code style and project structure.
- Keep changes scoped to the issue you are addressing.
- Add or update tests where behavior changes.

## Contract security review checklist

Before a release that publishes Wasm artifacts, review contract changes against the checklist below. Findings must be scoped to contract code and actionable; unresolved high-risk findings block the release or require a reviewed exception recorded with the release artifacts.

### Authorization and call boundaries

- [ ] Every state-changing entry point enforces the required `require_auth` / authorization checks.
- [ ] Authorization is checked on the caller identity, not on caller-supplied arguments.
- [ ] Cross-contract calls validate the callee address and do not trust returned data blindly.
- [ ] Admin/owner-only operations cannot be invoked through indirect call paths.

### Arithmetic

- [ ] All arithmetic uses checked operations (`checked_add`, `checked_sub`, `checked_mul`, `checked_div`) or is provably bounded.
- [ ] No unchecked casts between integer widths that can truncate or wrap.
- [ ] Rounding and fee/share calculations are documented and tested at boundaries.

### Storage

- [ ] Storage keys are namespaced and cannot collide across contract instances.
- [ ] Persistent/temporary/instance storage choices match the data lifetime requirements.
- [ ] No unbounded iteration over storage that can exceed ledger limits.
- [ ] Storage is not left in an inconsistent state on early return or panic.

### Upgrade paths

- [ ] Upgrade entry points are authorization-gated and cannot be called by arbitrary accounts.
- [ ] Storage layout changes are backward compatible or include an explicit migration.
- [ ] Initialization/upgrade functions cannot be re-run to reset state unexpectedly.

### Dependencies

- [ ] Contract dependencies are audited (`cargo audit` / `cargo deny`) and no unresolved advisories remain.
- [ ] New dependencies are pinned and reviewed for maintenance status.

## Release gate

The release gate runs supported Rust/Soroban static checks and a dependency audit scoped to contract code. Tool versions and generated reports are retained with the release artifacts. Verify the gate against a known safe baseline and a controlled unsafe test fixture before publishing.

## Reporting issues

Open an issue with a clear description, reproduction steps, and expected behavior.
