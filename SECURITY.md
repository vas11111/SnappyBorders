# Security

SnappyBorders is a local macOS application. It opens no TCP/UDP listener and
has no external Swift package dependencies. It links Apple's system frameworks,
including the private SkyLight API; keep macOS and the build toolchain patched.
Private API behavior still needs verification on each supported macOS release.

The local control socket is restricted to the current effective user, with
peer credential checks, a private directory, a lifetime instance lock, bounded
messages, deadlines, and socket I/O outside the rendering thread. An executable
startup config intentionally runs code as that user. Configs require trusted
ownership, permissions and parent directories, and execute directly without
shell interpretation of the file path. They are not a sandbox for untrusted code.

Run the checks documented in [README.md](README.md#checks-and-dependency-updates).
The [.security](.security/) checker preserves minimum-version policy checks and
can query current OSV advisories for resolved public dependencies. It does not
execute manifests or install dependencies. Swift `Package.resolved` schemas
1–3 are supported; repository URLs must first be reviewed and listed in
`swift_public_repositories` before their package identities are sent to OSV.
Branch/revision-only pins and symlinked dependency files require separate
review. Unsupported lockfiles fail CI rather than silently passing.

An empty dependency inventory means no package advisory queries were needed;
it does not certify the operating system, installed software, private/git
dependencies or vendored code. The ignored `JankyBorders/` reference checkout
and generated build trees are outside the shipped source and audit scope.

Policy reviewed on 2026-10-24. CI actions are pinned to verified release commits
and tracked by Dependabot. CI uses Python 3.15.1, which includes the certificate
bundle updates described in the [Python security release announcement](https://blog.python.org/2026/10/python-3151-3149-31317/).
Use patched Python tooling for online audits; Python 3.15.0 on a development
machine should be updated separately. Use the current Apple toolchain; upstream
Swift releases are listed on [Swift.org](https://www.swift.org/install/macos/).

Report vulnerabilities through the repository's Security tab when private
reporting is enabled. Avoid publishing exploit details in ordinary issues.
