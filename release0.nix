let pkgs = import <nixpkgs> { };
in pkgs.haskellPackages.callCabal2nix "wstunnel" ./. { }
