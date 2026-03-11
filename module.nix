{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.ai-agents;
  jsonFormat = pkgs.formats.json { };

  # Agents under XDG config use xdg.configFile; others use home.file
  xdgAgents = [ "opencode" ];

  agentSkillsPath = {
    opencode = "opencode/skills";
    claude = ".claude/skills";
    cursor = ".cursor/skills";
  };

  skillType = lib.mkOptionType {
    name = "skillSource";
    description = "path or { url, ref?, rev? }";
    check =
      x: builtins.isPath x || builtins.isString x || (builtins.isAttrs x && (x ? url || x ? outPath));
  };

  isGitSkill = entry: builtins.isAttrs entry && entry ? url;
  storeSkills = builtins.filter (e: !isGitSkill e) cfg.skills;
  gitSkillEntries = builtins.filter isGitSkill cfg.skills;

  mcpServerType = lib.types.submodule {
    freeformType = jsonFormat.type;
    options = {
      type = lib.mkOption {
        type = lib.types.str;
        default = "stdio";
        description = "MCP server type (stdio, remote, sse).";
      };
    };
  };

  resolvedStoreSkills = storeSkills;

  mergedSkills = pkgs.runCommandLocal "merged-ai-agent-skills" { } ''
    mkdir -p $out
    ${lib.concatMapStringsSep "\n" (src: ''
      find "${src}" -name "SKILL.md" -type f | while read -r skillfile; do
        skill_dir="$(dirname "$skillfile")"
        name="$(basename "$skill_dir")"
        rm -rf "$out/$name"
        cp -rL "$skill_dir" "$out/$name"
      done
    '') resolvedStoreSkills}
  '';

  # Build final opencode config with shared MCPs merged in.
  # Agent-specific MCPs (from opencode.config.mcp) override shared on name collision.
  finalOpencodeConfig =
    let
      sharedMcps = cfg.mcpServers;
      agentMcps = cfg.opencode.config.mcp or { };
      mergedMcps = sharedMcps // agentMcps;
      baseConfig = builtins.removeAttrs cfg.opencode.config [ "mcp" ];
    in
    if mergedMcps == { } then cfg.opencode.config else baseConfig // { mcp = mergedMcps; };

  isXdgAgent = agent: builtins.elem agent xdgAgents;

  agentSkillsAbsPath =
    agent:
    if isXdgAgent agent then
      "${config.xdg.configHome}/${agentSkillsPath.${agent}}"
    else
      "${config.home.homeDirectory}/${agentSkillsPath.${agent}}";

  cacheDir = "${config.xdg.cacheHome}/nix-ai-agent-skills";

  gitSkillsScript =
    let
      agentDirs = map agentSkillsAbsPath cfg.agents;
      agentDirsStr = lib.concatMapStringsSep " " (d: ''"${d}"'') agentDirs;

      cloneSnippets = lib.concatMapStrings (
        entry:
        let
          urlHash = builtins.hashString "sha256" entry.url;
          ref = entry.ref or "";
          rev = entry.rev or "";
        in
        ''
          _repo="${cacheDir}/repos/${urlHash}"
          if [ -d "$_repo/.git" ]; then
            ${pkgs.git}/bin/git -C "$_repo" fetch --quiet 2>/dev/null || \
              echo "Warning: failed to fetch ${entry.url}" >&2
            ${
              if rev != "" then
                ''
                  ${pkgs.git}/bin/git -C "$_repo" checkout --quiet ${lib.escapeShellArg rev} 2>/dev/null
                ''
              else
                ''
                  ${pkgs.git}/bin/git -C "$_repo" pull --quiet 2>/dev/null || true
                ''
            }
          else
            ${pkgs.git}/bin/git clone --quiet \
              ${lib.optionalString (ref != "") "--branch ${lib.escapeShellArg ref}"} \
              ${lib.escapeShellArg entry.url} "$_repo" 2>/dev/null || \
              echo "Warning: failed to clone ${entry.url}" >&2
            ${lib.optionalString (rev != "") ''
              ${pkgs.git}/bin/git -C "$_repo" checkout --quiet ${lib.escapeShellArg rev}
            ''}
          fi
        ''
      ) gitSkillEntries;

      deploySnippets = lib.concatMapStrings (
        entry:
        let
          urlHash = builtins.hashString "sha256" entry.url;
        in
        ''
          if [ -d "${cacheDir}/repos/${urlHash}" ]; then
            find "${cacheDir}/repos/${urlHash}" -name "SKILL.md" -type f | while read -r skillfile; do
              skill_dir="$(dirname "$skillfile")"
              name="$(basename "$skill_dir")"
              for _dir in "''${_AGENT_DIRS[@]}"; do
                ln -snf "$skill_dir" "$_dir/$name"
              done
            done
          fi
        ''
      ) gitSkillEntries;
    in
    ''
      _AGENT_DIRS=(${agentDirsStr})
      mkdir -p "${cacheDir}/repos"

      # Ensure agent skill directories exist
      for _dir in "''${_AGENT_DIRS[@]}"; do
        mkdir -p "$_dir"
      done

      # Clean old git-managed symlinks (those pointing to cache dir)
      for _dir in "''${_AGENT_DIRS[@]}"; do
        for _entry in "$_dir"/*; do
          [ -L "$_entry" ] || continue
          case "$(readlink "$_entry")" in
            "${cacheDir}"/*) rm -f "$_entry" ;;
          esac
        done
      done

      # Clone/update repos
      ${cloneSnippets}

      # Deploy git skills (overrides store skills on name collision)
      ${deploySnippets}
    '';

in
{
  options.programs.ai-agents = {
    enable = lib.mkEnableOption "AI agent configuration management";

    agents = lib.mkOption {
      type = lib.types.listOf (
        lib.types.enum [
          "opencode"
          "claude"
          "cursor"
        ]
      );
      default = [ "opencode" ];
      description = "Which AI agents to configure.";
    };

    skills = lib.mkOption {
      type = lib.types.listOf skillType;
      default = [ ];
      description = ''
        Ordered list of skills sources. Each entry is either:

        - A path (typically a flake input with `flake = false`), or
        - An attrset with `url` (required), `ref` (optional branch/tag),
          and `rev` (optional commit SHA) for git-based skills.

        Path/flake entries are resolved at build time and deployed via
        Home Manager file management.

        Git URL entries are cloned at Home Manager activation time,
        running as the user with access to SSH keys and git credentials.
        This makes them suitable for private repositories. Git skills
        override store skills on name collision.

        Skills are discovered recursively, where any SKILL.md files at any
        nested depth are found and their parent directory becomes the
        skill name in the merged output.
      '';
    };

    mcpServers = lib.mkOption {
      type = lib.types.attrsOf mcpServerType;
      default = { };
      description = ''
        Shared MCP server definitions applied to all enabled agents.
        Per-agent config overrides shared definitions on name collision.
      '';
    };

    opencode = lib.mkOption {
      type = lib.types.submodule {
        options = {
          config = lib.mkOption {
            type = jsonFormat.type;
            default = { };
            description = ''
              Configuration attrset serialized to opencode.json.
              Shared mcpServers are automatically injected into the mcp key.
              Agent-specific mcp entries here override shared definitions
              on name collision.
            '';
          };

          agentsFile = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Path to AGENTS.md source file.";
          };

          agentsText = lib.mkOption {
            type = lib.types.nullOr lib.types.lines;
            default = null;
            description = "Inline text content for AGENTS.md.";
          };
        };
      };
      default = { };
      description = "OpenCode agent configuration.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # Assertions
      {
        assertions = [
          {
            assertion = !(cfg.opencode.agentsFile != null && cfg.opencode.agentsText != null);
            message = "programs.ai-agents.opencode.agentsFile and agentsText are mutually exclusive.";
          }
        ];
      }

      # Store skills deployment (build-time, via Home Manager file management)
      (lib.mkIf (storeSkills != [ ]) {
        # XDG-managed agents (opencode)
        xdg.configFile = lib.listToAttrs (
          map (
            agent:
            lib.nameValuePair agentSkillsPath.${agent} {
              source = mergedSkills;
              recursive = true;
            }
          ) (builtins.filter isXdgAgent cfg.agents)
        );

        # Home-managed agents (claude, cursor)
        home.file = lib.listToAttrs (
          map (
            agent:
            lib.nameValuePair agentSkillsPath.${agent} {
              source = mergedSkills;
              recursive = true;
            }
          ) (builtins.filter (a: !isXdgAgent a) cfg.agents)
        );
      })

      # Git skills deployment (activation-time, as user)
      (lib.mkIf (gitSkillEntries != [ ]) {
        home.activation.deployGitSkills = lib.hm.dag.entryAfter [ "linkGeneration" ] gitSkillsScript;
      })

      # OpenCode: generate opencode.json
      (lib.mkIf (builtins.elem "opencode" cfg.agents && finalOpencodeConfig != { }) {
        xdg.configFile."opencode/opencode.json".source =
          jsonFormat.generate "opencode.json" finalOpencodeConfig;
      })

      # OpenCode: AGENTS.md from file
      (lib.mkIf (cfg.opencode.agentsFile != null) {
        xdg.configFile."opencode/AGENTS.md".source = cfg.opencode.agentsFile;
      })

      # OpenCode: AGENTS.md from inline text
      (lib.mkIf (cfg.opencode.agentsText != null) {
        xdg.configFile."opencode/AGENTS.md".text = cfg.opencode.agentsText;
      })
    ]
  );
}
