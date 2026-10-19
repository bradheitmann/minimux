# Main branch protection

`main-ruleset.json` is the repository ruleset payload. Checking it in does not
activate GitHub enforcement. An administrator must apply it once using an
account with Administration: write permission:

```sh
gh api --method POST repos/OWNER/REPO/rulesets --input .github/main-ruleset.json
```

Replace OWNER/REPO with this repository. If a ruleset with the same purpose
already exists, inspect it and update that ruleset rather than creating a
conflicting duplicate. Inspect the effective branch rules after applying it.

The payload requires a pull request and current successful checks from the
GitHub Actions app, blocks force pushes/deletion, requires resolved threads,
and grants no bypass actors. Review count is zero so a solo maintainer can
merge their own tested PR; this does not enforce independent human approval.
Independent review remains a separate acceptance obligation. Increase the
approval count when a second authorized reviewer is available. New check
names must be successful on a candidate PR before activating their requirement.
