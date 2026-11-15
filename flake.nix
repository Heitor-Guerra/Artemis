{
  description = "Development shell for Artemis Lua development and tests";

  inputs.nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.zst";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      glibcLibraryDirectory = "${pkgs.glibc}/lib";
      opensslDevDirectory = "${pkgs.openssl.dev}";
      opensslLibraryDirectory = "${pkgs.openssl.out}/lib";
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
          openssl.dev
          openssl.out
          gnutar
          coreutils
          unzip
          m4
        ];

        # luasystem's Linux build links against librt. The Nix glibc output
        # provides the compatibility linker name in its library directory.
        RT_DIR = "${pkgs.glibc}";
        RT_LIBDIR = glibcLibraryDirectory;
        CRYPTO_DIR = opensslDevDirectory;
        CRYPTO_LIBDIR = opensslLibraryDirectory;
        OPENSSL_DIR = opensslDevDirectory;
        OPENSSL_LIBDIR = opensslLibraryDirectory;

        shellHook = ''
          echo "Welcome to the Lua development shell!"

          # LuaRocks stores project settings in .luarocks/config-5.4.lua.
          # A project wrapper selects that configuration and the lua_modules
          # tree. Bootstrap it for fresh clones and CI checkouts when absent.
          if [ ! -x ./luarocks ]; then
            echo "Initializing the project-local LuaRocks environment..."
            if ! luarocks init --lua-version=5.4; then
              echo "ERROR: Could not initialize the project-local LuaRocks environment." >&2
              return 1
            fi
          fi

          mkdir -p .luarocks

          if [ ! -e "${glibcLibraryDirectory}/librt.so" ]; then
            echo "ERROR: ${glibcLibraryDirectory}/librt.so was not found in the Nix glibc output."
            return 1
          fi

          if [ ! -f "${opensslDevDirectory}/include/openssl/crypto.h" ]; then
            echo "ERROR: OpenSSL development headers were not found." >&2
            return 1
          fi

          if [ ! -e "${opensslLibraryDirectory}/libcrypto.so" ]; then
            echo "ERROR: OpenSSL crypto library was not found." >&2
            return 1
          fi


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

          if ! ./luarocks config variables.OPENSSL_DIR "${opensslDevDirectory}" --scope=project >/dev/null; then
            echo "ERROR: Could not configure OPENSSL_DIR." >&2
            return 1
          fi

          if ! ./luarocks config variables.OPENSSL_LIBDIR "${opensslLibraryDirectory}" --scope=project >/dev/null; then
            echo "ERROR: Could not configure OPENSSL_LIBDIR." >&2
            return 1
          fi

          if ! ./luarocks config variables.CRYPTO_DIR "${opensslDevDirectory}" --scope=project >/dev/null; then
            echo "ERROR: Could not write CRYPTO_DIR to the LuaRocks project configuration." >&2
            return 1
          fi

          if ! ./luarocks config variables.CRYPTO_LIBDIR "${opensslLibraryDirectory}" --scope=project >/dev/null; then
            echo "ERROR: Could not write CRYPTO_LIBDIR to the LuaRocks project configuration." >&2
            return 1
          fi

          active_rt_libdir="$(./luarocks config variables.RT_LIBDIR)"
          if [ "$active_rt_libdir" != "${glibcLibraryDirectory}" ]; then
            echo "ERROR: LuaRocks is not reading the configured project RT_LIBDIR." >&2
            return 1
          fi

          active_crypto_libdir="$(./luarocks config variables.CRYPTO_LIBDIR)"
          if [ "$active_crypto_libdir" != "${opensslLibraryDirectory}" ]; then
            echo "ERROR: LuaRocks is not reading the configured CRYPTO_LIBDIR." >&2
            return 1
          fi

          active_openssl_libdir="$(./luarocks config variables.OPENSSL_LIBDIR)"
          if [ "$active_openssl_libdir" != "${opensslLibraryDirectory}" ]; then
            echo "ERROR: LuaRocks is not reading the configured OPENSSL_LIBDIR." >&2
            return 1
          fi

          eval "$(./luarocks path --bin)"
        '';
      };
    };
}
