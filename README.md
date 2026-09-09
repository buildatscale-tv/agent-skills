# Agent Skills

Portable AI agent skills that work across harnesses (Claude Code, OpenCode, Cursor, etc.).

## Install

```bash
npx skills add https://github.com/buildatscale-tv/agent-skills
```

Or copy the skill directory into your project.

## Skills

### [/devbox](skills/devbox/)

Create, manage, and tear down [Namespace](https://namespace.so/?ref=buildatscale-yt) devboxes from any AI agent. Supports GitHub issue dispatch, ad-hoc tasks, multi-variant model comparison, and plain devbox management.

### [/nano-banana](skills/nano-banana/)

Generate images with Google's Gemini image models (Nano Banana Flash/Pro/2, up to 4K) from any AI agent — hero images, illustrations, icons, backgrounds, or standalone artwork. Supports aspect ratios, reference images for style guidance, and resolution control.

### [/env-setup-git](skills/env-setup-git/)

Layer human git identity, slash-free branch names, and Co-authored-by blocking onto Cursor Cloud Agent `/env-setup`. Includes `git-identity.sh`, commit hooks, and instructions for personal Cloud Agent secrets (`GIT_AUTHOR_*_OVERRIDE`, optional `GIT_SIGNING_SSH_KEY`).

### [/promo-video](skills/promo-video/)

Create professional promotional videos using Remotion with AI voiceover (ElevenLabs) and background music. Guides a 5-phase workflow: product analysis, theme selection, Remotion build, voiceover generation, and final render with music.

## License

MIT
