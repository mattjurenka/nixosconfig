# A reader for the shells Claude Code keeps to itself.
#
# `Bash(run_in_background: true)` hands the agent a shell it polls privately
# with BashOutput, and the editor in front of it is told nothing: a Zed thread
# shows the "running in background with ID ..." notice and then goes quiet,
# however much that shell is printing. The adapter is not hiding it on
# purpose -- claude-agent-acp does publish background tasks, but only inside
# `_meta.jetbrains.air` and only to a client that advertised the matching
# capability, which Zed does not (see modules/features/zed.nix). There is no
# setting on either side that turns this on.
#
# The output is on disk, though, one appended file per shell, so the way to see
# a dev server an agent started is to read that file rather than to wait for
# the agent to quote it. claude-shells is that reader: a table of what is
# running and a `tail -F` over all of it. Details of the layout, and why a
# spool file alone does not mean a shell was backgrounded, are in the script.
{ ... }:
{
  # Both machines that run agents need this, and they install packages through
  # different module systems: the laptop through home-manager (zed.nix, beside
  # the editor the shells are invisible in) and brain-vm through
  # environment.systemPackages, where a Zed task opened in a remote project
  # lands. Shared from here so the two cannot drift.
  config.flake.lib.mkClaudeShells =
    { pkgs }:
    pkgs.writeShellApplication {
      name = "claude-shells";
      runtimeInputs = [
        pkgs.jq
        pkgs.coreutils
        pkgs.findutils
        pkgs.gawk
        pkgs.gnugrep
        pkgs.gnused
      ];
      # No errexit: a `tail` that dies when its file is rotated away, or a
      # `stat` on a spool file a session just cleaned up, is an ordinary event
      # in a loop that watches other people's processes -- not a reason to take
      # the viewer down and leave the pane blank.
      bashOptions = [ "nounset" "pipefail" ];
      text = builtins.readFile ./claude-shells/claude-shells.sh;
    };
}
