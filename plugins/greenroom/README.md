# greenroom plugin

Sets up [greenroom](https://github.com/samotherguy/greenroom) for the repo you are in: a chat page behind Tailscale where someone who does not code asks for changes in plain English, watches them in a live preview, and presses Send to open a pull request. Claude Code runs headless in a git worktree of the repo with a tool list that allows editing and building and nothing else.

```
/greenroom:setup "Studio name" --owner You --port 4401 --preview-port 4323 --serve-port 8445 --allow you@github
```

One greenroom clone on the machine serves every project. The command adds a `studio/` folder to the repo (config, prompts, model list, allow-list, systemd unit), creates the `../<repo>-playground` worktree, starts a user service, and puts it on the tailnet with `tailscale serve`. It detects Astro or Vite for the preview command and a Cloudflare D1 database for the live-data snapshot and the wrangler tool rules. Then Claude fills in the project map in `studio/PROMPT.bare.md` and checks the tiers.

Rerunning is safe: edited files are kept, the service is refreshed. Keys go in `~/.config/greenroom.env`.

The script alone, without Claude:

```
node plugins/greenroom/skills/greenroom-setup/setup.mjs "Studio name" --owner You --allow you@github --serve
```
