{
  description = "Development shell to allow easy containerized development in nix";

  inputs.nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.zst";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          lua5_4
          lua54Packages.luarocks-nix
          lua-language-server
          unzip
        ];

        shellHook = ''
          echo "Welcome to the Lua development shell!"

          # Load the project-local LuaRocks environment.
          if [ -x ./luarocks ]; then
            eval "$(./luarocks path --bin)"
          fi
        '';
      };
    };
}
