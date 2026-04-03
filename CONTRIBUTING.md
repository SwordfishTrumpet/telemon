# Contributing to Telemon

Thank you for your interest in contributing to Telemon! This document provides guidelines and instructions for contributing.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Making Changes](#making-changes)
- [Testing](#testing)
- [Submitting Changes](#submitting-changes)
- [Style Guidelines](#style-guidelines)
- [Commit Messages](#commit-messages)

## Code of Conduct

This project adheres to a standard of professional and respectful interaction. Please:
- Be respectful and inclusive
- Accept constructive criticism gracefully
- Focus on what's best for the project and its users

## Getting Started

1. Fork the repository on GitHub
2. Clone your fork locally:
   ```bash
   git clone https://github.com/YOUR_USERNAME/telemon.git
   cd telemon
   ```
3. Create a branch for your changes:
   ```bash
   git checkout -b feature/my-new-feature
   ```

## Development Setup

### Prerequisites

- Bash 4.0+
- shellcheck (for linting)
- git

### Install Development Tools

```bash
# Ubuntu/Debian
sudo apt-get install shellcheck

# macOS
brew install shellcheck

# Fedora
sudo dnf install ShellCheck
```

### Configure Git Hooks

```bash
# Optional: Add pre-commit hook for shellcheck
cat > .git/hooks/pre-commit << 'EOF'
#!/bin/bash
shellcheck telemon.sh install.sh uninstall.sh update.sh telemon-admin.sh || exit 1
EOF
chmod +x .git/hooks/pre-commit
```

## Making Changes

### Types of Contributions

We welcome:
- Bug fixes
- New check types (CPU, memory, etc. are examples)
- Documentation improvements
- Feature enhancements
- Performance optimizations
- Test coverage

### Before You Start

1. Check existing issues to avoid duplicates
2. For major changes, open an issue first to discuss design
3. Ensure your change aligns with the project's philosophy (set & forget, silent when healthy)

### File Structure

```
telemon/
├── telemon.sh          # Main monitoring script
├── install.sh          # Installation script
├── uninstall.sh        # Uninstallation script
├── update.sh           # Update mechanism
├── telemon-admin.sh    # Administration utility
├── .env.example        # Configuration template
├── systemd/            # Systemd service files
├── docs/               # Documentation
│   ├── man/            # Man pages
│   └── QUICKREF.md     # Quick reference
└── .github/            # GitHub templates and workflows
```

## Testing

### Syntax Checking

Always verify bash syntax before submitting:

```bash
bash -n telemon.sh
bash -n install.sh
bash -n uninstall.sh
bash -n update.sh
bash -n telemon-admin.sh
```

### ShellCheck

Run shellcheck on all scripts:

```bash
shellcheck telemon.sh install.sh uninstall.sh update.sh telemon-admin.sh
```

### Manual Testing

1. Create a test `.env`:
   ```bash
   cp .env.example .env
   # Edit with test Telegram credentials
   ```

2. Run validation:
   ```bash
   bash telemon-admin.sh validate
   ```

3. Run a test cycle:
   ```bash
   bash telemon.sh
   ```

4. Check logs:
   ```bash
   cat telemon.log
   ```

### Test Scenarios

When adding new features, test:
- First run (bootstrap message)
- State transitions (OK → WARNING → CRITICAL)
- Resolution alerts (CRITICAL → OK)
- Confirmation count behavior
- Configuration validation
- Error handling (missing commands, permissions)

## Submitting Changes

### Pull Request Process

1. Update the CHANGELOG.md with your changes
2. Ensure all tests pass (syntax check, shellcheck)
3. Update documentation if needed
4. Submit PR with clear description of changes

### PR Checklist

- [ ] Code follows style guidelines
- [ ] Shellcheck passes with no warnings
- [ ] Syntax check passes (`bash -n`)
- [ ] Documentation updated
- [ ] CHANGELOG.md updated
- [ ] Commit messages are clear

## Style Guidelines

### Bash Style

- Use `#!/usr/bin/env bash` shebang
- Use `set -euo pipefail` for safety
- Quote all variables: `"$variable"`
- Use `[[ ]]` for tests, not `[ ]`
- Use local variables in functions
- Indent with 4 spaces

### Function Documentation

```bash
# ===========================================================================
# CHECK: Description of what this checks
# ===========================================================================
check_something() {
    local var1="$1"
    local var2="$2"
    
    # Implementation
}
```

### Variable Naming

- UPPER_CASE for environment variables and constants
- lower_case for local variables
- descriptive_names (not x, y, z)

### Error Handling

```bash
# Check for required commands
if ! command -v required_cmd &>/dev/null; then
    log "ERROR" "required_cmd not found"
    return 1
fi

# Handle failures gracefully
cmd || {
    log "WARN" "cmd failed, continuing..."
    return 0
}
```

## Commit Messages

Use clear, descriptive commit messages:

```
Add feature: brief description

Longer explanation if needed. Explain what changed
and why, not just what was done.

- Bullet points for multiple changes
- Reference issues: Fixes #123
```

### Commit Types

- `Add feature:` - New functionality
- `Fix:` - Bug fixes
- `Update:` - Changes to existing functionality
- `Refactor:` - Code restructuring without behavior change
- `Docs:` - Documentation changes
- `Test:` - Test additions/changes

## Questions?

- Open an issue for questions or discussion
- Check existing documentation first
- Be patient - maintainers are volunteers

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

Thank you for contributing to Telemon!
