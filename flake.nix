{
  description = "shimmie2, a taggable image board";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }: {
    nixosModules.default = import ./nix/module.nix { inherit self; };
    packages = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ]
      (system: {
        default = (import nixpkgs { inherit system; }).stdenv.mkDerivation {
          pname = "shimmie2";
          version = "2.11.0";
          src = self;
          installPhase = ''
            runHook preInstall
            mkdir -p "$out/share/shimmie2"
            cp -r . "$out/share/shimmie2"
            runHook postInstall
          '';
        };
      });
  };
}
