{
  description = "AI agent configuration and skills management";

  outputs =
    { self }:
    {
      homeManagerModules = {
        default = self.homeManagerModules.ai-agents;
        ai-agents = import ./module.nix;
      };
    };
}
