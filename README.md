# nix-ai-skills

A Nix flake that aggregates AI agent skills from multiple repositories into a
single merged directory, deployed via Home Manager to the correct config path
for each agent.

## How It Works

1. **Discovery** -- Each skills source is scanned recursively for `SKILL.md`
   files at any depth. The parent directory of each `SKILL.md` becomes the
   skill name.
2. **Merge** -- Skills from all sources are merged into a single flat
   directory. Sources are processed in order; later entries override earlier
   ones on name collision (last wins).
3. **Deploy** -- The merged skills directory is symlinked into each enabled
   agent's config path via Home Manager.

This means a skill at `repo/.cursor/skills/foo/bar/SKILL.md` is surfaced
as `bar/` in the final output, alongside skills from other repos.

## Agent Paths

| Agent | Skills Path |
|---|---|
| `opencode` | `~/.config/opencode/skills/` |
| `claude` | `~/.claude/skills/` |
| `cursor` | `~/.cursor/skills/` |

## Installation

Add `nix-ai-skills` to your flake inputs:

```nix
# flake.nix
{
  inputs = {
    # ... existing inputs ...

    ai-skills.url = "github:mattstruble/nix-ai-skills";

    # Skills repositories as flake inputs (pinned via flake.lock)
    skills-core = {
      url = "github:<repo-1>/skills";
      flake = false;
    };
  };
}
```

Then import the Home Manager module and configure it. Since `inputs` is
typically passed via `extraSpecialArgs`, your Home Manager modules can
reference the skills inputs directly:

```nix
# home.nix (or wherever your Home Manager config lives)
{ inputs, ... }:

{
  imports = [ inputs.ai-skills.homeManagerModules.default ];

  programs.ai-skills = {
    enable = true;
    agents = [ "opencode" "claude" ];
    skills = [
      inputs.skills-core
    ];
  };
}
```

## Skills Sources

Skills can be provided as either **flake inputs** or **git URLs**. You can
mix both in the same list.

### Flake Inputs

Add the skills repo as a `flake = false` input and reference it directly.
Versions are pinned automatically via `flake.lock`.

```nix
# flake.nix
inputs.skills-core = {
  url = "github:<repo>/skills";
  flake = false;
};

# home.nix
programs.ai-skills.skills = [ inputs.skills-core ];
```

### Git URLs

Specify a git URL directly in the module config. Useful for private repos
that only some machines have access to, since each machine only fetches the
URLs in its own config.

```nix
programs.ai-skills.skills = [
  inputs.skills-core                # flake input (public, pinned by flake.lock)

  {
    url = "https://github.com/me/my-skills";
    ref = "v1.0.0";                 # pin to a tag
  }

  {
    url = "git@github.com:corp/internal-skills.git";   # SSH, private
    rev = "abc123def456789...";     # pin to exact commit
  }

  {
    url = "https://github.com/me/dev-skills";
    ref = "main";                   # track a branch (requires --impure)
  }
];
```

**Git URL options:**

| Field | Required | Description |
|---|---|---|
| `url` | Yes | Git repository URL (HTTPS or SSH) |
| `ref` | No | Branch or tag name |
| `rev` | No | Exact commit SHA |

### Pure Eval and Pinning

Nix flakes evaluate in pure mode by default. This affects git URL entries:

- **With `rev`** -- Works in pure eval. Fully reproducible.
- **With only `ref` (no `rev`)** -- Requires `--impure` flag. Nix resolves
  the ref to a commit at evaluation time.
- **Neither `ref` nor `rev`** -- Requires `--impure`. Fetches the default
  branch HEAD.

Flake inputs are unaffected -- they are always pinned via `flake.lock`.

```bash
# Standard rebuild (pure eval -- git URL entries need rev)
darwin-rebuild switch --flake .

# Impure rebuild (allows git URLs without rev)
darwin-rebuild switch --flake . --impure
```

## Configuration Reference

### `programs.ai-skills.enable`

- **Type:** `bool`
- **Default:** `false`
- **Description:** Whether to enable AI agent skills management.

### `programs.ai-skills.agents`

- **Type:** `listOf (enum [ "opencode" "claude" "cursor" ])`
- **Default:** `[ "opencode" ]`
- **Description:** Which AI agents to configure skills for. The merged skills
  directory is deployed to each agent's config path.

### `programs.ai-skills.skills`

- **Type:** `listOf (either path { url; ref?; rev?; })`
- **Default:** `[]`
- **Description:** Ordered list of skills sources. Each entry is either a path
  (flake input) or an attrset with `url`, optional `ref`, and optional `rev`.
  Skills are discovered recursively. Later entries take priority on name
  conflicts.

## Updating

### Flake Inputs

```bash
# Update all inputs
nix flake update

# Update a single skills repo
nix flake update skills-core
```

### Git URL Entries

Manually update `rev` or `ref` in your Home Manager config. There is no
lock file for git URL entries -- `rev` is the pinning mechanism.


## License

MIT
