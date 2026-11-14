{
  description = "Development shell for Artemis Lua development and tests";

  inputs.nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.zst";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      glibcLibraryDirectory = "${pkgs.glibc}/lib";
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          lua5_4
          lua54Packages.luarocks-nix
          lua-language-server
          gcc
          gnumake
          glibc
          glibc.dev
          curl
          gnutar
          coreutils
          unzip
        ];

        # luasystem's Linux build links against librt. The Nix glibc output
        # provides the compatibility linker name in its library directory.
        RT_DIR = "${pkgs.glibc}";
        RT_LIBDIR = glibcLibraryDirectory;

        shellHook = ''
          echo "Welcome to the Lua development shell!"

          # Configure the path in LuaRocks itself. Exporting RT_LIBDIR only
          # in the shell is insufficient because dependency detection reads
          # the LuaRocks configuration's variables table.
          if ! ./luarocks config variables.RT_DIR "${pkgs.glibc}" --scope=project >/dev/null; then
            echo "ERROR: Could not write RT_DIR to the LuaRocks project configuration." >&2
            return 1
          fi

          if ! ./luarocks config variables.RT_LIBDIR "${glibcLibraryDirectory}" --scope=project >/dev/null; then
            echo "ERROR: Could not write RT_LIBDIR to the LuaRocks project configuration." >&2
            return 1
          fi

          active_rt_libdir="$(./luarocks config variables.RT_LIBDIR)"
          if [ "$active_rt_libdir" != "${glibcLibraryDirectory}" ]; then
            echo "ERROR: LuaRocks is not reading the configured project RT_LIBDIR." >&2
            echo "Expected: ${glibcLibraryDirectory}" >&2
            echo "Received: $active_rt_libdir" >&2
            return 1
          fi

          eval "$(./luarocks path --bin)"
        '';
      };
    };
}
