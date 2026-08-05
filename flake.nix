{
  description = "Verification toolchain for converge";

  inputs.nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.2405";

  outputs = { nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.tlaplus
            pkgs.why3
            pkgs.z3
          ];
          WHY3DATA = "${pkgs.why3}/share/why3";
          WHY3LIB = "${pkgs.why3}/lib/why3";
          Z3PATH = "${pkgs.z3}/bin/z3";
        };
      });
    };
}
