# TorShield AI Agent Instructions

Welcome to the `tor-firewall` repository! If you are an AI coding assistant or agent operating in this codebase, you **MUST** adhere strictly to the following rules to maintain our OSS Production Readiness standards.

## 1. Local Verification (Makefile)
Do not guess how to run tests or linters. We use a `Makefile` to standardize all local verification.
- **Linting**: Run `make lint`. This triggers `shellcheck` on all bash scripts.
- **Formatting**: Run `make format`. This triggers `shfmt -w -i 2 -ci` on all bash scripts. You **must** run this after editing any `.sh` file.
- **Testing**: Run `make test`. This executes our functional **BATS** (Bash Automated Testing System) test suite located in the `tests/` directory.
- **Full CI**: Run `make ci` to run linting, formatting checks, and BATS tests together. You must ensure this passes before concluding your task.

## 2. Commit Standards (Conventional Commits)
We use `Release Please` to automate semantic versioning and changelog generation. Therefore, **all commit messages must strictly follow the Conventional Commits v1.0.0 specification**.
- `feat(scope): ...` for new features
- `fix(scope): ...` for bug fixes
- `docs(scope): ...` for README or markdown updates
- `chore( scope): ...` for CI/CD, dependency, or maintenance updates
- `test(scope): ...` for updates to the `tests/` directory

## 3. Code Architecture
- **Bash**: Do not write monolithic top-to-bottom bash scripts. All procedural logic must be wrapped in a `main()` function and invoked at the end of the file with `main "$@"`.
- **Python Data Extractors**: Do not use inline Python inside bash strings (e.g., `python3 - <<'PY'`). Put complex parsing (JSON/HTML) into dedicated, cleanly typed python scripts inside the `src/` directory.

## 4. Root/Sudo Execution
- The main `setup.sh` script requires root privileges to manipulate `iptables` and `ipset`. 
- **Testing bypass**: When writing BATS tests for bash wrappers, set `ROOT_BYPASS=1` in the environment to bypass the root check block, preventing the tests from hanging on sudo password prompts in CI.
