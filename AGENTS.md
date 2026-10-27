# Repository Guidelines

## Project Structure & Module Organization

iPorts is currently an uninitialized workspace: no source code, tests, assets, dependency manifests, or Git metadata are present. Establish the layout with the first implementation and document it in `README.md`.

For a new layout, group application code in `src/`, automated tests in `tests/`, and static resources in `assets/` when needed. Follow framework conventions if they require another structure. Keep related modules together and avoid adding empty placeholder directories.

## Build, Test, and Development Commands

No build, test, or local development commands are configured yet. When introducing the toolchain, document exact commands for dependency installation, local startup, formatting, building, and testing in `README.md`. Include required runtime versions and configuration prerequisites.

Run the documented checks before requesting review. Keep commands reproducible from the repository root and report any checks that could not run, including the reason.

## Coding Style & Naming Conventions

Use the selected language's standard formatter and naming conventions, then preserve established patterns. Until tooling defines indentation, use four spaces for code and follow format-specific requirements for configuration files.

Choose descriptive names, keep modules focused, and avoid unrelated renaming or refactoring. Add formatter or linter configuration alongside the first implementation. Preserve public interfaces unless a breaking change is explicitly intended.

## Testing Guidelines

No test framework or coverage threshold is configured. Select tests compatible with the chosen stack and document how to run them. Name tests after observable behavior, such as `RejectsInvalidPort`, using the framework's naming style.

Cover changed behavior, boundary inputs, and failure paths. Add regression tests for bug fixes; keep tests deterministic and independent of production services.

## Commit & Pull Request Guidelines

No Git history is available to establish existing conventions. Use concise, imperative commit subjects, such as `Add port discovery`, and keep commits focused.

Pull requests should explain the problem, implementation, verification results, and configuration or compatibility impact. Link relevant issues and include screenshots for visible interface changes.

## Security & Configuration

Keep credentials and machine-specific settings outside version control. Provide placeholder configuration examples, validate external input, and document required permissions and environment variables.
