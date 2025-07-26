{ pkgs ? import (fetchTarball
  "https://github.com/NixOS/nixpkgs/archive/2a2130494ad647f953593c4e84ea4df839fbd68c.tar.gz")
  { } }:

pkgs.mkShell {
  buildInputs = with pkgs; [ ];
  shellHook = ''
    zsh
  '';
}
