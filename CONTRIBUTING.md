# Contributing to TorShield

Thank you for your interest in contributing to TorShield! As an open-source project, we rely on the community to keep this kernel-level Tor exit node firewall robust, secure, and performant.

## Code of Conduct
Please be respectful and considerate to all maintainers and contributors.

## Development Setup
This project consists primarily of standard bash scripts. To work on the project, you need:
- `make`
- `shellcheck` (for linting)
- `shfmt` (for formatting)

On macOS: `brew install shellcheck shfmt`
On Ubuntu/Debian: `sudo apt install shellcheck shfmt`

## Verification Checks
Before submitting a pull request, you **must** ensure your code passes local verification checks:

1. **Linting:** Run `make lint` to check for bash syntax issues and potential bugs using `shellcheck`.
2. **Formatting:** Run `make format` to automatically format all bash scripts according to our style guidelines (2-space indent).

We strictly enforce these checks in our Continuous Integration (CI) pipeline. PRs with linting or formatting errors will not be merged.

## Commit Guidelines
We strictly follow the [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) specification for all commit messages. This is **required** because we use automated tools (Release Please) to govern semantic versioning and generate changelogs based on commit history.

### Commit Format
```
type(optional-scope): description
```

### Allowed Types
- `feat`: A new feature (e.g., adding IPv6 support)
- `fix`: A bug fix (e.g., resolving an iptables syntax error)
- `docs`: Documentation only changes (e.g., updating README)
- `chore`: Maintenance tasks, dependency updates, CI/CD changes
- `refactor`: A code change that neither fixes a bug nor adds a feature
- `test`: Adding missing tests or correcting existing tests

### Examples
- `feat(setup): add support for custom ipset names`
- `fix(core): resolve rollback failure on missing backup file`
- `docs(readme): add cron scheduling example`
- `chore(ci): update github actions versions`

## Submitting Changes
1. Fork the repository
2. Create a feature branch (`git checkout -b feat/my-new-feature`)
3. Make your changes
4. Test thoroughly — never push untested firewall changes!
5. Run `make ci` locally to verify linting and formatting
6. Commit using Conventional Commits
7. Push to your branch and open a Pull Request
