# Check 4 — Test E re-run: load-bearing subset map

Re-runs #147 §4.2 Test E on the now-stable `/run/gemini-creds` mount path
(under `$HOME/tmp/gem-148/`, avoiding the `/tmp` Docker Desktop fileshare
gap noted in #147 §4.2 footnote).

Command shape per subset (identical to Check 3, only the mount source changes):

```sh
docker run --rm -v "$HOME/tmp/gem-148/<subset>:/run/gemini-creds:ro" \
  crewrig/e2e-gemini:latest bash -c '
    set -e
    mkdir -p /home/agent/.gemini
    cp -a /run/gemini-creds/. /home/agent/.gemini/
    chown -R agent:agent /home/agent/.gemini 2>/dev/null || :
    timeout 30 gemini -p "name one colour, one word"
  '
```

No `GOOGLE_CLOUD_ACCESS_TOKEN`, no `GOOGLE_GENAI_USE_GCA` (verified
unset in Check 3; identical environment in all rows).

| Subset | Files included | EXIT | Outcome / error snippet |
|---|---|---|---|
| S1 | `oauth_creds.json`, `settings.json` | 1 | `Gemini CLI is not running in a trusted directory. To proceed, either use \`--skip-trust\`, set \`GEMINI_CLI_TRUST_WORKSPACE=true\`, or trust this directory in interactive mode.` |
| S2 | S1 + `google_accounts.json` | 1 | Same "trusted directory" error as S1. |
| S3 | S2 + `installation_id` | 1 | Same "trusted directory" error as S1. |
| S4 | S3 + `trustedFolders.json` | 0 | Healthy answer: `Blue.` |
| S5 | `oauth_creds.json`, `settings.json`, `trustedFolders.json` (minimum) | 0 | Healthy answer: `Blue, Hello.` — confirms S2/S3 additions are NOT load-bearing once `trustedFolders.json` is present. |

## Minimal load-bearing set (empirical, this image revision)

```text
oauth_creds.json
settings.json
trustedFolders.json
```

This narrows #147's §2.1 "candidate load-bearing" column by one — Test E
in #147 conjectured `{oauth_creds.json, settings.json}` as the floor,
but the `crewrig/e2e-gemini:latest` image's Gemini CLI version enforces
trusted-folder mode for `/workspace`, so `trustedFolders.json` joins the
floor. None of `google_accounts.json`, `google_account_id` (absent from
the captured bundle), `installation_id`, `gemini-credentials.json`
(absent), `projects.json`, `state.json`, or `history/` are load-bearing
for `gemini -p` under the new mount pattern.

## Files in the captured bundle (`~/.crewrig-e2e/gemini/`)

See `bundle-full.txt`. Two entries (`google_account_id`,
`gemini-credentials.json`) are absent from this developer's sandboxed
login output, matching #147 §2.1's "❌" captures-today column — and
empirically demonstrated above as not load-bearing.
