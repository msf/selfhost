# Agent notes

Same standards apply to humans and agents. Read README.md and DESIGN.md first.

## Shell scripts
- `set -euo pipefail`; check critical preconditions, fail loud with a clear message.
- Success is silent: no progress chatter, no ASCII art — at most one outcome line.

## Code & docs
- Self-documenting code; comment only non-obvious *why*.
- Don't add docs that restate code. Service-specific notes live in that service's dir.
