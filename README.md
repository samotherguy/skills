# skills

Everything I have written for Claude Code, in one place. Two kinds of thing live here:

- **Skills**: a folder with a `SKILL.md` and its scripts. Install one with the [skills](https://skills.sh) CLI, which works across Claude Code, Codex, Cursor and the rest.
- **Plugins**: skills plus commands, hooks or setup scripts, packaged for Claude Code's plugin system. This repo is also a Claude Code marketplace.

## Install

```sh
# a skill, into any agent the skills CLI supports
npx skills@latest add Abhyuday98/skills --skill building-ubuntu-server-disk

# a plugin, into Claude Code
/plugin marketplace add Abhyuday98/skills
/plugin install cowork@abhyuday-skills
/plugin install derebrand-claude-code@abhyuday-skills
/plugin install greenroom@abhyuday-skills
```

## What is here

| Name | Kind | What it does |
| --- | --- | --- |
| [building-ubuntu-server-disk](skills/building-ubuntu-server-disk/SKILL.md) | skill | Builds a bootable Ubuntu Server onto a spare SSD from a running Ubuntu machine with debootstrap and a chroot, no ISO or installer: user, SSH keys, NVIDIA driver, Docker and Tailscale preset, so the disk moves into another machine and answers SSH on first boot. |
| [claude-video-generator](skills/claude-video-generator/SKILL.md) | skill | Produces a narrated demo or walkthrough video fully headless: a recorded terminal session, an app tour from a real browser, HTML slides, offline TTS narration, and an assembler where the audio length sets the screen time. Article: [A twenty-minute narrated film, made with no screen, no microphone and nobody at the keyboard](https://medium.com/@abhyudaysamadder/a-twenty-minute-narrated-film-made-with-no-screen-no-microphone-and-nobody-at-the-keyboard-19d4c67876fc). |
| [cowork](plugins/cowork/skills/cowork/SKILL.md) | plugin | Cowork mode: hand over a goal, get back a verified file. Research first, the right document skill second, and it opens the result to check it before reporting. |
| [derebrand-claude-code](plugins/derebrand-claude-code/skills/derebrand-claude-code/SKILL.md) | plugin | Renames the Claude Code VS Code extension to a neutral "Assistant" with a plain icon and no orange, and re-applies it after an extension update overwrites it. |
| [greenroom](plugins/greenroom/README.md) | plugin | `/greenroom:setup` gives a repo a [greenroom](https://github.com/Abhyuday98/greenroom): a chat page behind Tailscale where someone who does not code asks for changes, sees them in a live preview, and sends them as a pull request. |

These started life as three separate repos; this one is where they are maintained now.

## Adding one

A skill: make `skills/<name>/SKILL.md` with `name` and `description` in the front matter, scripts next to it. A plugin: make `plugins/<name>/` with a `.claude-plugin/plugin.json` and add an entry to `.claude-plugin/marketplace.json`. Push, and it is installable.
