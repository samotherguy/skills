# Cowork mode for Claude Code

Hand over a goal, get back a finished file that Claude has already opened and
checked. Not a plan, not a chat answer, not a code fence you have to save
yourself.

```
/cowork turn the notes in ./research into a 5-page board update
```

Claude researches first, picks the right format skill second, builds the
document, converts it back to images or text, looks at what it actually
rendered, fixes what is wrong, and tells you where the file is.

## Install

Two lines inside Claude Code:

```
/plugin marketplace add samotherguy/claude-code-cowork
/plugin install cowork@cowork
```

Then add the document skills, which are published separately by Anthropic:

```
/plugin marketplace add anthropics/skills
/plugin install document-skills@anthropic-agent-skills
/plugin install example-skills@anthropic-agent-skills
```

That is the whole setup. `/cowork` is available immediately, and the skill also
triggers on its own whenever you ask for something file-shaped.

## System dependencies

The verification step is the point of this plugin, and it needs real renderers.
Without them Claude can still write files but cannot look at them.

```bash
# Debian / Ubuntu
sudo apt install -y libreoffice poppler-utils pandoc
pip install pypdf pdfplumber reportlab pypdfium2
npm install -g docx     # then export NODE_PATH=$(npm root -g)

# macOS
brew install --cask libreoffice
brew install poppler pandoc
```

Run `bash scripts/check-deps.sh` to see what is missing.

Optional but worth having: the Playwright MCP server, so Claude can open and
screenshot pages it builds rather than guessing at them.

## What it actually changes

Claude Code's default instinct is to answer you in the terminal. This plugin
changes the instinct to: produce the artifact, then verify it.

- **Research before format.** Every fact, figure and source is settled before
  the `docx` or `pptx` skill is opened. Opening the format skill early anchors
  the model on mechanics before it has anything true to say.
- **Verification is not optional.** A `.docx` gets converted to PDF, rasterised,
  and read back as images. A spreadsheet gets its numbers recomputed rather than
  trusted. A file that was not reopened is not delivered.
- **A design pass before anything visual.** Named colours and typefaces are
  chosen up front, so output does not default to the machine-made look.
- **Parallel by default.** Independent research and drafting go out as
  subagents in one message.

## What is deliberately not here

This ships one skill and one command. It does not vendor a pile of other
people's skills. The document and design skills come from the public
[`anthropics/skills`](https://github.com/anthropics/skills) marketplace, which
is why the install above adds it directly rather than bundling a stale copy.

Anthropic's proprietary Cowork skills are not redistributed here.

## Licence

MIT. See [LICENSE](LICENSE).
