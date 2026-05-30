# Design note — #148 Gemini auth capture redesign

> **Scope:** Redesign `scripts/e2e/auth-gemini.sh` and `tests/e2e/defaults.toml [cli.gemini]` so that the e2e harness captures every load-bearing artifact of a healthy `~/.gemini/` and ships it into the container through a writable copy. Runner cleanup (`run.sh`, `e2e_gemini_refresh_access_token`, `timeout` wrapper) is **out of scope** — owned by #149.

Grounded entirely on `docs/research/gemini-cli-auth-blackbox.md` (#147). Section references below point into that document.

---

## Decision 1 — Capture scope: full top-level minus a denylist

**Choice.** Replace the curated allowlist in `auth-gemini.sh` by a **deny-listed `cp -R`** of `~/.gemini/` into `~/.crewrig-e2e/gemini/`, excluding only:

- `antigravity-browser-profile/` (~18k Chromium cache files — §2)
- `antigravity/` (sibling browser profile, observed in host inventory)
- `tmp/` (transient session scratch — §2)
- `*.bak`, `*.ori`, `*.orig` (Bucket D leftovers — §2.4)

**Why.** #147 §6.1 #1 explicitly recommends this, and §2.1 / §7 admit four files (`google_account_id`, `gemini-credentials.json`, `extension_integrity.json`, `acknowledgments/agents.json`) plus `history/` are present in working hosts but were never individually load-bearing-tested. Under-capture risks the same silent-hang class of bug we just spent #147 diagnosing. Over-capture cost is bytes on disk + a few extra lines; the script runs once per developer per machine.

A denylist is more robust than extending the allowlist because future Gemini CLI versions may add new auth artifacts — the denylist captures them by default, the allowlist would silently miss them.

**Blast radius for developer.** Replace the `[ -f ... ]` post-flight checks for the full file set; keep `oauth_creds.json` + `settings.json` as the minimum guards (anything else missing is a host weirdness, not a login-flow failure). API-key contamination check still runs against `oauth_creds.json` and `settings.json` only.

---

## Decision 2 — Container-side mount-and-copy: inline `bash -c` in TOML (Option A)

**Choice.** Embed the copy-then-exec sequence directly in `tests/e2e/defaults.toml [cli.gemini].command`, matching the exact shape of #147 §5:

```toml
command = [
  "bash", "-c",
  "mkdir -p /home/agent/.gemini && cp -R /run/gemini-creds/. /home/agent/.gemini/ && chown -R agent:agent /home/agent/.gemini 2>/dev/null || true; exec gemini \"$@\"",
  "sh"
]
```

**Why.** Three reasons rule out the alternatives:

1. **Parity with the existing Ollama workaround in `tests/e2e/local.toml`.** That file uses the same `bash -c "...; exec ..."` shape for the Ollama keypair mount (verified in `local.toml.example`). Two divergent patterns for the same problem class fragments the mental model.
2. **Debuggability without rebuilding the image.** A helper script shipped in `crewrig/e2e-gemini:latest` (Option B) requires a Docker image rebuild whenever the bootstrap changes. Inline TOML edits land in seconds and survive `task e2e:test` without `task e2e:build:gemini`.
3. **Single-source-of-truth for the contract.** With the command inline, reading `defaults.toml [cli.gemini]` tells the full story of how the container boots. Option B splits the truth between TOML and Dockerfile; Option C splits it between TOML and a helper. The command is 4 statements — not big enough to justify the split.

The string is ugly. We accept the ugliness; it is bounded and self-documenting in context.

**Blast radius for developer.** Quote `\"$@\"` carefully — the existing `timeout 120 gemini \"$@\"` uses the same TOML-escaping pattern, model on it. The trailing `"sh"` is `$0` for `bash -c` (sets `argv[0]` for any error messages from inside the wrapper); preserve it.

---

## Decision 3 — `settings-headless.json` shadow mount: **drop**

**Choice.** Remove the `settings-headless.json` generation block from `auth-gemini.sh` (lines starting `HEADLESS_SETTINGS=`) and the matching mount line from `defaults.toml`.

**Why.** Concur with #147 §6.1 #3. Test D (§4.2) empirically demonstrated that with the fix pattern in place, `oauth-personal` authenticates headless `gemini -p` invocations without env injection. The `{}`-shadow was a workaround for the `:ro` write-hang misdiagnosed as a WebSocket bug (§ Executive summary #3) — once writes succeed, the shadow buys nothing. Keeping a dead workaround as "harmless fallback" (the current comment claims) just delays the next person's mental-model load.

**Blast radius for developer.** Both files change: delete the `printf '{}\n' > "$HEADLESS_SETTINGS"` block including its preceding `e2e_info` line in `auth-gemini.sh`, and delete the `settings-headless.json:/home/agent/.gemini/settings.json:ro` mount line in `defaults.toml`. Existing developer e2e dirs will retain a stale `settings-headless.json` file — harmless, swept up next time they delete `~/.crewrig-e2e/gemini/`.

---

## Decision 4 — Permission model & secrecy posture

**Choice.**

| Concern | Rule |
|---|---|
| Dir mode | `auth-gemini.sh` ends with `chmod 700 "$DIR"` after capture |
| File modes | Preserved by `cp -R` (host already enforces `0600` on `oauth_creds.json` / `gemini-credentials.json` / `settings.json` per §2.1) |
| `.gitignore` | **Not needed.** `~/.crewrig-e2e/` lives outside the repo root by design (per `e2e_cli_dir` in `auth-common.sh`). Defense-in-depth gitignore line is unnecessary noise. |
| README warning | Add a short note to the script's existing "Authenticated. Credentials persisted under $DIR." line: `"Bundle contains a long-lived OAuth refresh token. Treat ${DIR} like ~/.ssh — host-only, never sync to cloud storage, never ship in container images."` |

**Why.** The §8 `baseline.fs.txt` artifact shows `~/.crewrig-e2e/gemini/` at `drwxrwxrwx` today — readable by any other user on a shared dev box. The bundle's `oauth_creds.json` contains a refresh token good for the full Google account lifetime; `0700` on the parent dir is the minimum civilized posture. We do not encrypt at rest because (a) the container needs plaintext at run time, (b) #147 §1 scoped Keychain integration out as not used by the CLI itself, and (c) the e2e bundle is a developer-machine artifact, not a deployed secret — escalating to a vault adds operational friction without changing the threat model.

**Blast radius for developer.** One `chmod 700 "$DIR"` line at end of `auth-gemini.sh`. One sentence appended to the final `e2e_info` line. No new dependencies, no new env vars, no `.gitignore` edit.

---

## Decision 5 — `tests/e2e/defaults.toml` updates: TOML-only, runner contract preserved

**Choice.** Edit `defaults.toml [cli.gemini]` only. Do **not** touch `tests/e2e/run.sh` (lines 275–284 stay as-is for #149). Keep the full `env_keys` array (`GEMINI_API_KEY`, `GOOGLE_CLOUD_ACCESS_TOKEN`, `GOOGLE_GENAI_USE_GCA`) unchanged.

Resulting `[cli.gemini]` block:

```toml
[cli.gemini]
image        = "crewrig/e2e-gemini:latest"
# Container-side bootstrap: copy the :ro credentials bundle into a writable
# location owned by `agent`, then exec gemini. Lets ProjectRegistry.save()
# perform its atomic-write to projects.json (see issue #147 §5).
command      = [
  "bash", "-c",
  "mkdir -p /home/agent/.gemini && cp -R /run/gemini-creds/. /home/agent/.gemini/ && chown -R agent:agent /home/agent/.gemini 2>/dev/null || true; exec gemini \"$@\"",
  "sh"
]
command_args = []
mounts       = ["${CREWRIG_E2E_HOME}/gemini:/run/gemini-creds:ro"]
env_keys     = ["GEMINI_API_KEY", "GOOGLE_CLOUD_ACCESS_TOKEN", "GOOGLE_GENAI_USE_GCA"]
```

**Why.** #147 §4.2 Test D proved `GOOGLE_CLOUD_ACCESS_TOKEN` injection is **vestigial** but **harmless**. Removing it requires deleting the `run.sh` block (#149's job). Leaving it produces an env var Gemini ignores — zero runtime cost, preserves #149's independent landing. The contract this PR exposes to #149: "TOML mount path, command shape, and env_keys list are the contract surface; runner injection can be removed without touching them again." Verify by inspection: nothing in the new `command` reads `$GOOGLE_*` env vars, so adding/removing the env injection in `run.sh` cannot affect this TOML.

**Blast radius for developer.** One block rewrite in `defaults.toml`. The mount path changes from `/home/agent/.gemini` to `/run/gemini-creds` — this is a deliberate, observable rename so anyone debugging a failing run can `docker inspect` the container and immediately see "ah, the source is RO under `/run/gemini-creds`, the writable copy is the bootstrapped `/home/agent/.gemini`."

Wrap the `command` array with `# noqa`-style discipline only if the linter complains; the readable form is to keep the bash on a single line per `bash -c` convention.

---

## Decision 6 — CLI matrix maintenance

**Choice.** Update **two cells** in `docs/cli-matrix.md`:

1. **Row #21 (e2e dedicated-account auth flow), Gemini column.** Replace `{oauth_creds.json,settings.json}` with the broader `{oauth_creds.json, settings.json, google_accounts.json, google_account_id, installation_id, gemini-credentials.json, extension_integrity.json, trustedFolders.json, acknowledgments/, history/, projects.json, state.json, ...}` enumeration, and append a sentence: `Bundle is mounted :ro at /run/gemini-creds; a container-side wrapper copies it to /home/agent/.gemini before exec gemini (see issue #147 §5).`
2. **Row #22 (e2e pillar 01 — layered context), Gemini column.** Change `mounts ${CREWRIG_E2E_HOME}/gemini ro` → `mounts ${CREWRIG_E2E_HOME}/gemini at /run/gemini-creds ro, copy-on-boot to /home/agent/.gemini`. The truth of the mount path moved; the matrix must follow.

No `Parity gaps` entry changes — Claude continues to mount `~/.crewrig-e2e/claude` directly RO (no atomic-write pressure on its credential files), so the asymmetry is empirically justified and already documented as a behavior difference, not a gap.

**Why.** AGENTS.md "CLI Matrix Maintenance" lists `tests/e2e/defaults.toml` modifications as in the trigger surface. Drift here is a parity bug per the standing rule. Both affected rows already describe the mount mechanism; updating them is mechanical.

**Blast radius for developer.** Two cell edits. Same commit as the code change.

---

## Decision 7 — Test surface for the tester

The tester's brief beyond `task e2e:test passes`:

1. **Re-run #147 §4.2 Test E (minimal-bundle elimination) using the new `/run/gemini-creds` stable mount.** This is the test that was inconclusive in #147 because Docker Desktop fs sharing did not propagate `/tmp/gem-min/`. With the new mount path inside `~/.crewrig-e2e/`, fs sharing is already proven. Run with:
   - `oauth_creds.json` + `settings.json` only → expect EXIT=0 or specific error
   - Add one file at a time until passing
   Append the finding to `docs/research/gemini-cli-auth-blackbox.md` §4.2 Test E result column (replacing "inconclusive") and update §2.1 captured-today column accordingly.
2. **Wall-clock timing.** `time task e2e:test -- --cli gemini --scenario 01-layered-context`. Confirm < 10 s end-to-end (the previous `timeout 120 gemini` wrapper masked a hang; the new path should finish in single-digit seconds per #147 §4.1).
3. **Confirm `GOOGLE_CLOUD_ACCESS_TOKEN` injection is unneeded.** Temporarily unset it in `run.sh` (or comment out the injection block locally — do not commit) and verify the scenario still passes. This empirically validates the #149 cleanup contract before #149 lands.
4. **Negative test: simulate stale auth.** Remove `oauth_creds.json` from `~/.crewrig-e2e/gemini/` and confirm the scenario produces a clear, non-hanging failure (not a silent timeout).

---

## Handoff to developer — concrete edit checklist

1. **`scripts/e2e/auth-gemini.sh`** — replace the `docker run` block's post-flight section:
   - Replace the curated `[ -f ... ]` check with a `cp -R "$HOME/.gemini/." "$DIR/"` denylist using `--exclude` (or post-`cp` `rm -rf` of `antigravity-browser-profile`, `antigravity`, `tmp`, `*.bak`, `*.ori`, `*.orig` under `$DIR`).
   - Keep the post-flight existence check for `oauth_creds.json` and `settings.json` only.
   - Delete the `HEADLESS_SETTINGS=...; printf '{}\n' > "$HEADLESS_SETTINGS"` block + its `e2e_info` line.
   - Append `chmod 700 "$DIR"` after the existence check passes.
   - Extend the final `e2e_info` to include the "long-lived OAuth refresh token — treat like ~/.ssh" warning.
2. **`tests/e2e/defaults.toml`** — rewrite `[cli.gemini]` block per Decision 5; preserve `env_keys` unchanged.
3. **`docs/cli-matrix.md`** — update Row #21 and Row #22 Gemini cells per Decision 6.
4. **Do NOT touch:** `tests/e2e/run.sh`, `scripts/e2e/lib/auth-common.sh` (specifically `e2e_gemini_refresh_access_token`), `tests/e2e/lib/test-token-refresh.sh`. All owned by #149.
5. **Verify locally before push:**
   - `bash scripts/check-skill-versions.sh` (no community-config edits expected; should be a no-op)
   - `task e2e:auth:gemini` — re-run the interactive login; confirm the new files appear under `~/.crewrig-e2e/gemini/` and the dir is `0700`.
   - `task e2e:test -- --cli gemini` — single-digit-seconds completion expected.
6. **Commit message:** `🔐 Capture full ~/.gemini bundle and copy on boot (issue #148)` (Gitmoji per AGENTS.md).

---

## Open concerns for team-lead

- **`cp -R` of `history/`** copies any historical conversation transcripts from the developer's host into `~/.crewrig-e2e/gemini/`. This is a privacy consideration the developer should call out in the script's final warning. Recommend adding `history/` to the denylist if the load-bearing test (Decision 7 #1) shows the directory is not actually consulted at startup — saves bytes and removes a privacy surface. Cannot decide unilaterally because §4.2 Test E was inconclusive in #147; defer the final decision to the tester's empirical result.
- **API-key grep currently scans only `oauth_creds.json` + `settings.json`.** With broader capture, consider extending the grep to walk the full `$DIR` for `GEMINI_API_KEY|GOOGLE_API_KEY` patterns. Trade-off: catches more contamination, adds runtime; recommend doing it (one-time interactive script, perf is irrelevant).
