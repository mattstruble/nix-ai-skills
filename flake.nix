{
  description = "Aggregate AI agent skills from multiple repositories";

  outputs =
    { self }:
    {
      homeManagerModules = {
        default = self.homeManagerModules.ai-skills;
        ai-skills = import ./module.nix;
      };
    };
}
