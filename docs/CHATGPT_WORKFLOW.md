# ChatGPT Remote Workflow

This file confirms that ChatGPT can read and update the GitHub repository used by the VS Code lab workspace.

## Workflow

1. ChatGPT reviews or changes files in GitHub.
2. The lab VS Code workspace pulls the latest changes.
3. Scripts are run from the VS Code PowerShell terminal on the lab server or jump box.
4. Output or errors are pasted back into ChatGPT for analysis and follow-up changes.

## Pull latest changes in VS Code

```powershell
git pull
```

## Check current repository state

```powershell
git status
git log --oneline -5
```

## Current goal

Use this repository as a starting point for CyberArk API automation scripts, reporting, testing, and future onboarding/offboarding work.
