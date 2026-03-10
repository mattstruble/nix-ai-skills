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

  resolveSkill =
    entry:
    if builtins.isAttrs entry && entry ? url then
      builtins.fetchGit (
        {
          url = entry.url;
        }
        // lib.optionalAttrs (entry ? ref && entry.ref != "") { ref = entry.ref; }
        // lib.optionalAttrs (entry ? rev && entry.rev != "") { rev = entry.rev; }
      )
    else
      entry;

  resolvedSkills = map resolveSkill cfg.skills;

  mergedSkills = pkgs.runCommandLocal "merged-ai-agent-skills" { } ''
    mkdir -p $out
    ${lib.concatMapStringsSep "\n" (src: ''
      find "${src}" -name "SKILL.md" -type f | while read -r skillfile; do
        skill_dir="$(dirname "$skillfile")"
        name="$(basename "$skill_dir")"
        rm -rf "$out/$name"
        cp -rL "$skill_dir" "$out/$name"
      done
    '') resolvedSkills}
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
          and `rev` (optional commit SHA) for direct git fetching.

        Skills are discovered recursively, where any SKILL.md files at any
        nested depth are found and their parent directory becomes the
        skill name in the merged output.

        Later entries take priority on directory name conflicts.

        Git URL entries without `rev` require `--impure` for flake builds.
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

      # Skills deployment
      (lib.mkIf (cfg.skills != [ ]) {
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
