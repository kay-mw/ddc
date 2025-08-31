{
  pkgs ?
    import
      (fetchTarball "https://github.com/NixOS/nixpkgs/archive/dfb2f12e899db4876308eba6d93455ab7da304cd.tar.gz")
      { },
}:

pkgs.mkShell { buildInputs = with pkgs; [ zig_0_15 ]; }
