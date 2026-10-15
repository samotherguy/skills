---
name: greenroom-setup
description: Set up greenroom for a project. Use when asked to give a non-technical person a chat page that edits a site through Claude Code, or to add "the studio" to a repo. Creates studio/ in the repo, the playground worktree, the systemd service and the Tailscale Serve entry.
---

# greenroom setup

greenroom (github.com/samotherguy/greenroom) is one Node file: a phone-friendly chat page behind Tailscale where a
non-technical person asks for changes in plain English, watches them in a live preview, and presses Send to open a
pull request. Claude Code runs headless inside a git worktree of the repo (the playground) with a tool list that
allows editing and building, and nothing else. One greenroom clone serves every project on the machine; each project
keeps its own `studio/` folder with the config, prompts, model list, allow-list and service unit.

## Steps

1. Run the script from the repo root. It is idempotent: rerunning updates the service and leaves edited files alone.

   ```sh
   node ${CLAUDE_PLUGIN_ROOT}/skills/greenroom-setup/setup.mjs "<studio name>" --owner <reviewer first name> \
     --port <free port> --preview-port <free port> --serve-port <free https port> --allow <tailscale login> --serve
   ```

   Ports: the first project on a machine uses 4400/4322/8443; use the next free ones (the script refuses a port in use).
   `--allow` takes the reviewer's Tailscale login (`user@github`, `name@gmail.com`); the non-technical person's login
   is added later to `studio/allowed.txt` once they have joined the tailnet. `--serve` runs `sudo tailscale serve`;
   drop it if sudo needs a password and give the user the printed command instead.

   The script: clones or updates greenroom under `~/personal_projects/repos/greenroom` (override with `--greenroom`),
   writes `studio/greenroom.config.json` (preview command, D1 snapshot sync and tool lists detected from
   package.json and wrangler.jsonc, tiers from the directories that exist), copies `PROMPT.md`, `PROMPT.bare.md`,
   `models.json`, `model.txt`, writes `allowed.txt` and `studio/greenroom-<slug>.service` (for Astro also `studio/astro.preview.config.mjs`, which gives the preview its own Vite cache so the build never breaks it), adds the runtime files to
   `.gitignore`, creates the playground worktree at `../<repo>-playground` (copies `.dev.vars`, runs `npm ci` and the
   local D1 migrations), installs and starts the user service, enables linger, and checks the page answers.

2. Fill in `studio/PROMPT.bare.md`. Its "Where things live" line is a template. Read the repo and write one paragraph
   naming: where the fixed text is (copy file), where colours and type are, where pages and layouts are, where photos
   go, how content is added (migrations and the command to apply them), the build command. This is what small and
   local models get instead of the full harness prompt, so keep it to file paths and commands.

3. Write the suggestion chips. `ideas` in `studio/greenroom.config.json` is the list under "Some things you could say" on
   the chat page; the script writes generic placeholders. Replace them with five or six requests this site's owner would
   actually make, in their words, from what the repo holds: the pages that exist, the content types in the database or
   content folder (books, events, posts, products), the copy keys, photos. End an open-ended one with `…` so the
   chip drops the person into the input to finish it, e.g. `Add a new book to the catalog called…`.

4. Check `studio/greenroom.config.json`: the `tiers` globs (words = copy and images, content = data such as migrations,
   design = styles, pages, components, layouts), the `upload.dir`, and `sync.after` (the D1 snapshot command when the
   project has a database, otherwise empty). If the project has a design system skill, `PROMPT.md` already tells Claude
   to read it.

5. Keys. The service reads `~/.config/greenroom.env` (create it, mode 600, if missing). Claude models need nothing
   when Claude Code is signed in on the machine, or `ANTHROPIC_API_KEY`; OpenRouter entries need `OPENROUTER_API_KEY`.
   `studio/model.txt` picks the provider from `studio/models.json`; it is read on every message.

6. Verify, then commit `studio/` and the `.gitignore` change (no AI attribution trailers):

   ```sh
   systemctl --user status <slug>-studio --no-pager | head -5
   curl -s -o /dev/null -w '%{http_code}\n' -H 'Sec-Fetch-Dest: document' http://127.0.0.1:<port>/  # 403: no identity
   curl -s -H 'Sec-Fetch-Dest: document' -H 'Tailscale-User-Login: <allowed login>' http://127.0.0.1:<port>/ | grep -c '<studio name>' # 1 (without Sec-Fetch-Dest the request is proxied to the preview)
   curl -s -H 'Tailscale-User-Login: <allowed login>' -o /dev/null -w '%{http_code}\n' 'http://127.0.0.1:<port>/?preview'  # 200 once the dev server is up; any other path is proxied to it
   ```

7. Tell the user: the studio address (`https://<machine>.<tailnet>.ts.net:<serve-port>`), how to add the person
   (invite to the tailnet, install Tailscale on their phone, add their login to `studio/allowed.txt`, send the link, Add
   to Home Screen), and that nothing reaches the live site until they merge the PR.
