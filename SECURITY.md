# Security

CellBridge is a personal project, published as is. The design and its known weaknesses (a short pairing code, an unencrypted local control
channel) are described in the README under *Security notes*; please read them before relying on it.

Found something that is not listed there? Please report it privately through GitHub's *Report a vulnerability* (the repository's Security tab)
instead of opening a public issue.

Never commit signing material or keys: `*.p8`, `*.p12`, `*.mobileprovision`, `Local.xcconfig` and `.env*` are git-ignored, and the `secret-scan`
workflow scans the history on every push.
