{ ... }: {
  # Antigravity CLI (agy): Google's terminal coding agent, which took over
  # Gemini CLI's personal sign-in, so the Google AI plan's limits apply.
  # It speaks ACP as `agy acp`. Taken straight from nixpkgs.
  flake.modules.nixos.antigravity-cli = { pkgs, ... }: {
    environment.systemPackages = [ pkgs.antigravity-cli ];
  };
}
