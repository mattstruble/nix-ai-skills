{ config
, lib
, pkgs
, ...
}:

let
  cfg = config.programs.ai-skills;

  agentSkillsPath = {
    opencode = ".config/opencode/skills";
    claude = ".claude/skills";
    cursor = ".cursor/skills";
  };

  skillType = lib.mkOptionType {
    name = "skillSource";
    description = "path or { url, ref?, rev? }";
    check =
      x: builtins.isPath x || builtins.isString x || (builtins.isAttrs x && (x ? url || x ? outPath));
  };

  resolveSkill =
    entry:
    if builtins.isAttrs entry && entry ? url then
      builtins.fetchGit
        (
          {
            url = entry.url;
          }
          // lib.optionalAttrs (entry ? ref && entry.ref != "") { ref = entry.ref; }
          // lib.optionalAttrs (entry ? rev && entry.rev != "") { rev = entry.rev; }
        )
    else
      entry;

  resolvedSkills = map resolveSkill cfg.skills;

  mergedSkills = pkgs.runCommandLocal "merged-ai-skills" { } ''
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

in
{
  options.programs.ai-skills = {
    enable = lib.mkEnableOption "AI agent skills management";

    agents = lib.mkOption {
      type = lib.types.listOf (
        lib.types.enum [
          "opencode"
          "claude"
          "cursor"
        ]
      );
      default = [ "opencode" ];
      description = "Which AI agents to configure skills for.";
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
  };

  config = lib.mkIf cfg.enable {
    home.file = lib.listToAttrs (
      map
        (
          agent:
          lib.nameValuePair agentSkillsPath.${agent} {
            source = mergedSkills;
            recursive = true;
          }
        )
        cfg.agents
    );
  };
}
