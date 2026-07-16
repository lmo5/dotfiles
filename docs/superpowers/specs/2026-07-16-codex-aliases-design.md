# Codex Alias Design

Add two Codex aliases beside the existing Claude Code aliases in
`shell/.shell/.aliases`:

```sh
alias x='codex'
alias xyolo='codex --dangerously-bypass-approvals-and-sandbox'
```

Keep the existing Claude aliases unchanged. `xyolo` disables approvals and
sandboxing, so it is intended only for trusted workspaces.

Verify by sourcing the shared aliases and inspecting both definitions:

```sh
source ~/.shell/.aliases
alias x
alias xyolo
```
