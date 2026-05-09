{
  description = "ddc";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/68a8af93ff4297686cb68880845e61e5e2e41d92";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
    in
    {
      devShells."${system}".default =
        let
          pkgs = import nixpkgs { inherit system; };
        in
        pkgs.mkShell {
          packages = with pkgs; [
            zig_0_16
          ];
          shellHook = ''
            export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global"
          '';
        };
    };
}
