{
  description = "Cantrip: batteries-included Haskell scripting, Nix-native";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forEachSystem = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      haskellPackagesFor =
        pkgs:
        pkgs.haskellPackages.extend (
          hself: _: { cantrip-hs = hself.callCabal2nix "cantrip-hs" ./. { }; }
        );
      # What the runner passes to GHC, so scripts need no LANGUAGE pragmas.
      scriptExtensions = [
        "-XOverloadedStrings"
        "-XQuasiQuotes"
      ];

      # The `cantrip` runner. `libraries` adds Haskell packages scripts may import.
      mkRunner =
        {
          pkgs,
          libraries ? (_: [ ]),
        }:
        let
          hp = haskellPackagesFor pkgs;
          scriptGhc = hp.ghcWithPackages (h: [ h.cantrip-hs ] ++ libraries h);
        in
        pkgs.writers.writeHaskellBin "cantrip" {
          ghc = hp.ghc;
          # A list, not a function: before 26.05 the writers only accepted lists.
          libraries = [ hp.cantrip-hs ];
          ghcArgs = [ "-O2" ];
          makeWrapperArgs = [
            "--set-default"
            "CANTRIP_GHC"
            "${scriptGhc}/bin/ghc"
          ];
        } (builtins.readFile ./runner/cantrip.hs);

      # A script as a Nix package, named `name`. A file is compiled the way the
      # runner compiles it, plus -Wall. A directory is built from `main`, and
      # `ghc --make` follows its imports. `libraries` adds to cantrip-hs.
      mkCantrip =
        {
          pkgs,
          name,
          src,
          main ? "Main.hs",
          libraries ? (_: [ ]),
        }:
        let
          hp = haskellPackagesFor pkgs;
          libs = h: [ h.cantrip-hs ] ++ libraries h;
        in
        if builtins.readFileType src == "directory" then
          pkgs.stdenv.mkDerivation {
            inherit name src;
            nativeBuildInputs = [ (hp.ghcWithPackages libs) ];
            buildPhase = ''
              ghc -O2 -threaded -Wall ${builtins.concatStringsSep " " scriptExtensions} --make "${main}" -o "${name}"
            '';
            installPhase = ''
              install -Dm755 "${name}" "$out/bin/${name}"
            '';
          }
        else
          pkgs.writers.writeHaskellBin name {
            ghc = hp.ghc;
            # A list, not a function: before 26.05 the writers only accepted lists.
            libraries = libs hp;
            ghcArgs = [
              "-O2"
              "-Wall"
            ] ++ scriptExtensions;
          } (builtins.readFile src);

      # The API reference as a static site (the GitHub Pages root): Haddock's
      # HTML, plus `.nojekyll` so Pages serves every file as it is. Haddock
      # lists undocumented exports but exits 0, so this phase fails on them.
      docsFor =
        pkgs:
        let
          pkg =
            (pkgs.haskell.lib.compose.doHaddock (haskellPackagesFor pkgs).cantrip-hs).overrideAttrs
              (_: {
                haddockPhase = ''
                  runHook preHaddock
                  ./Setup haddock --html --haddock-option=--no-tmp-comp-dir '--html-location=https://hackage.haskell.org/package/$pkg-$version/docs' 2>&1 | tee haddock.log
                  # Haddock lists each undocumented export, indented, after "Missing documentation".
                  missing=$(awk '/Missing documentation for:/ { m = 1; next } m && /^    [^ ]/ { print; next } { m = 0 }' haddock.log)
                  if [ -n "$missing" ]; then
                    echo "error: exports without Haddock comments:" >&2
                    echo "$missing" >&2
                    exit 1
                  fi
                  runHook postHaddock
                '';
              });
        in
        pkgs.runCommand "cantrip-hs-docs" { } ''
          cp -r --no-preserve=mode ${pkg.doc}/share/doc/${pkg.pname}-${pkg.version}/html $out
          # The internal syntax library is linked by this package's Hackage URL; keep those links on the site.
          grep -rl --null 'hackage.haskell.org/package/${pkg.pname}-${pkg.version}/docs/' $out | xargs -0 sed -i 's|https://hackage.haskell.org/package/${pkg.pname}-${pkg.version}/docs/||g'
          touch $out/.nojekyll
        '';
    in
    {
      lib = { inherit mkRunner mkCantrip; };

      packages = forEachSystem (pkgs: {
        default = (haskellPackagesFor pkgs).cantrip-hs;
        cantrip = mkRunner { inherit pkgs; };
        docs = docsFor pkgs;
      });

      # `nix flake check`: warning-free build + tests, lint, the examples built
      # with the runner's settings (the shell tour and git-sweep also run), and
      # the runner itself end to end.
      checks = forEachSystem (
        pkgs:
        let
          hp = haskellPackagesFor pkgs;
          cantrip = mkRunner { inherit pkgs; };
          scriptGhc = hp.ghcWithPackages (h: [ h.cantrip-hs ]);
          example =
            name:
            pkgs.writers.writeHaskellBin name {
              ghc = hp.ghc;
              libraries = [ hp.cantrip-hs ];
              ghcArgs = [
                "-Wall"
                "-Werror"
              ]
              ++ scriptExtensions;
            } (builtins.readFile ./examples/${name}.hs);
        in
        {
          build = pkgs.haskell.lib.appendConfigureFlag hp.cantrip-hs "--ghc-option=-Werror";
          docs = docsFor pkgs;
          # Prose is reflowed to 80 columns (.prettierrc.json); `nix fmt` fixes it.
          markdown = pkgs.runCommand "cantrip-hs-markdown" { nativeBuildInputs = [ pkgs.prettier ]; } ''
            cd ${./.}
            prettier --check README.md CHANGELOG.md
            touch "$out"
          '';
          lint =
            pkgs.runCommand "cantrip-hs-lint"
              {
                nativeBuildInputs = [
                  pkgs.fourmolu
                  pkgs.hlint
                  pkgs.cabal-install
                ];
              }
              ''
                cd ${./.}
                fourmolu --mode check src syntax test runner
                fourmolu --mode check ${toString (map (x: "--ghc-opt ${x}") scriptExtensions)} examples
                hlint src syntax test runner
                # Examples are written for readers new to Haskell: explicit lambdas stay.
                hlint examples ${toString scriptExtensions} --ignore="Avoid lambda"
                HOME="$TMPDIR" cabal check
                # Every README block under `<!-- example: PATH -->` must match PATH exactly.
                awk -v dir="$TMPDIR" '
                  /^<!-- example: .* -->$/ { target = $3; next }
                  target != "" && /^```haskell$/ { n++; out = dir "/block-" n ".hs"; print n, target >> (dir "/blocks"); copying = 1; target = ""; next }
                  copying && /^```$/ { copying = 0; next }
                  copying { print > out }
                ' README.md
                test -s "$TMPDIR/blocks"
                while read -r n target; do diff "$TMPDIR/block-$n.hs" "$target"; done < "$TMPDIR/blocks"
                touch "$out"
              '';
          example-refresh-token = example "refresh-token";
          example-bump-counter = example "bump-counter";
          example-shell-tour = example "shell-tour";
          # The tour's commands (find, grep, sort, uname, ...) all exist in the build sandbox.
          example-shell-tour-runs = pkgs.runCommand "cantrip-hs-shell-tour-runs" {
            nativeBuildInputs = [ (example "shell-tour") ];
          } ''shell-tour ${./examples} ${./examples/shell-tour.hs} | tee "$out"'';
          # A directory of two modules, built with lib.mkCantrip and run.
          example-greet-modules-runs =
            pkgs.runCommand "cantrip-hs-greet-modules-runs"
              {
                nativeBuildInputs = [
                  (mkCantrip {
                    inherit pkgs;
                    name = "greet-modules";
                    src = ./examples/greet-modules;
                  })
                ];
              }
              ''
                test "$(greet-modules)" = "hello world"
                test "$(greet-modules Ada)" = "hello Ada"
                touch "$out"
              '';
          example-git-sweep-runs =
            pkgs.runCommand "cantrip-hs-git-sweep-runs"
              {
                nativeBuildInputs = [
                  (example "git-sweep")
                  pkgs.git
                ];
              }
              ''
                export HOME=$TMPDIR
                git init -q -b main repo && cd repo
                git config user.email t@example.com && git config user.name t
                git commit -q --allow-empty -m init
                for b in feature-a feature-b; do
                  git switch -q -c "$b" && git commit -q --allow-empty -m "add ''${b#feature-}"
                  git switch -q main && git merge -q --no-ff "$b" -m "merge $b"
                done
                git switch -q -c wip && git commit -q --allow-empty -m wip && git switch -q main
                test "$(git-sweep --dry-run)" = "$(printf 'feature-a: add a\nfeature-b: add b\nwould delete 2 branches')"
                if git-sweep --dryrun 2>/dev/null; then echo "a mistyped flag was accepted"; exit 1; fi
                if git-sweep --base nope 2>/dev/null; then echo "a missing base was accepted"; exit 1; fi
                git-sweep | tee "$out"
                test "$(git branch --format='%(refname:short)' | tr '\n' ' ')" = "main wip "
              '';
          runner =
            pkgs.runCommand "cantrip-hs-runner"
              {
                nativeBuildInputs = [ cantrip ];
              }
              ''
                export HOME=$TMPDIR
                # Count compiles: the runner calls this instead of GHC.
                printf '#!/bin/sh\necho >> %s/compiles\nexec %s "$@"\n' "$TMPDIR" "${scriptGhc}/bin/ghc" > ghc
                chmod +x ghc
                export CANTRIP_GHC=$PWD/ghc
                compiles() { wc -l < "$TMPDIR/compiles"; }
                cat > hello <<'EOF'
                #!/usr/bin/env cantrip
                import Cantrip

                main :: IO ()
                main = script $ \argv -> do
                    args <- parseArgs ["NAME"] argv
                    let name = positional "NAME" args
                    run [sh|echo hello ''${name}|]
                EOF
                test "$(cantrip hello 'big world')" = "hello big world"
                test "$(cantrip hello --help)" = "usage: hello NAME"
                test "$(compiles)" = 1 || { echo "a cached script was compiled again"; exit 1; }
                # An edit is a different script.
                echo >> hello
                test "$(cantrip hello again)" = "hello again"
                test "$(compiles)" = 2 || { echo "an edited script ran from the cache"; exit 1; }
                if cantrip hello 2> err; then echo "a missing argument was accepted"; exit 1; fi
                grep -q '^error: missing argument: NAME' err
                # Compile errors point at the script and its own line numbers.
                cat > broken <<'EOF'
                #!/usr/bin/env cantrip
                import Cantrip

                main :: IO ()
                main = script $ \argv -> run [sh|echo ''${length argv}|]
                EOF
                if cantrip broken 2> err; then echo "an expression inside ''${...} compiled"; exit 1; fi
                grep -q '^broken:5:' err && grep -q 'only a variable name' err
                touch "$out"
              '';
        }
      );

      # `nix fmt` rewraps the Markdown. With no arguments it covers the docs.
      formatter = forEachSystem (
        pkgs:
        pkgs.writeShellScriptBin "fmt" ''
          if [ "$#" -eq 0 ]; then set -- README.md CHANGELOG.md; fi
          exec ${pkgs.prettier}/bin/prettier --write "$@"
        ''
      );

      devShells = forEachSystem (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.haskellPackages.ghc
            pkgs.haskellPackages.haskell-language-server
            pkgs.haskellPackages.cabal-install
            pkgs.fourmolu
            pkgs.haskellPackages.hlint
            pkgs.zlib
          ];
        };
      });
    };
}
