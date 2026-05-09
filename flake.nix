{
  description = "ddc";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/6308c3b21396534d8aaeac46179c14c439a89b8a";
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
            zig_0_15
          ];
          shellHook = ''
            export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global"
          '';
        };
    };
}
