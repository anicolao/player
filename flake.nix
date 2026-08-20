{
  description = "Player iOS development shell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      system = "aarch64-darwin";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      devShells.${system}.default = pkgs.mkShellNoCC {
        packages = with pkgs; [
          bashInteractive
          git
          jq
          ripgrep
        ];

        shellHook = ''
          export DEVELOPER_DIR="''${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

          if [[ "''${PLAYER_SKIP_SIMULATOR_LAUNCH:-0}" != "1" ]]; then
            player_repository_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
            player_simulator_launcher="$player_repository_root/apps/ios/scripts/launch-simulator.sh"
            if [[ -x "$player_simulator_launcher" ]]; then
              "$player_simulator_launcher"
            fi
          fi
        '';
      };
    };
}
