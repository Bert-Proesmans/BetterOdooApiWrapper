{
  description = "A minimal Python ORM wrapper for the Odoo API.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.systems.url = "github:nix-systems/default";
  inputs.treefmt-nix.url = "github:numtide/treefmt-nix";
  inputs.treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, systems, treefmt-nix }:
    let
      # __forSystems = nixpkgs.lib.genAttrs (import systems);
      __forSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" ];
      __forPackages = __forSystems (system: nixpkgs.legacyPackages.${system});
      # Helper creating attribute sets for each supported system.
      eachSystem = mapFn: __forSystems (system: mapFn __forPackages.${system});

      pyProject = nixpkgs.lib.importTOML ./pyproject.toml;
    in
    {
      packages = eachSystem (pkgs: {
        default = pkgs.python3Packages.buildPythonPackage {
          pyproject = true;
          pname = pyProject.project.name;
          inherit (pyProject.project) version;

          src = ./.;

          build-system = [ pkgs.python3Packages.setuptools ];
          pythonImportsCheck = pyProject.tool.setuptools.packages;

          meta = {
            inherit (pyProject.project) description;
            inherit (pyProject.project.urls) homepage;
            license = pkgs.lib.licenses.mit;
          };
        };
      });

      devShells = eachSystem (pkgs: {
        default = pkgs.mkShellNoCC {
          packages =
            let
              customPython = (pkgs.python3.override {
                packageOverrides = packagesFinal: _: {
                  betterOdooApiWrapper = packagesFinal.mkPythonEditablePackage {
                    pname = pyProject.project.name;
                    inherit (pyProject.project) version;
                    root = "$REPO_ROOT";
                  };
                };
              }).withPackages (ps: [ ps.betterOdooApiWrapper ]);
            in
            [
              pkgs.git
              customPython
              #
              (pkgs.writeShellApplication {
                name = "invoke-tests";
                runtimeInputs = [ pkgs.nix-fast-build ];
                text = ''
                  cd "$REPO_ROOT" && nix-fast-build
                '';
              })
            ];

          shellHook = ''
            # ERROR; Assumes the devshell is executed from a (sub-)directory of the repository.
            # This command will give the wrong result when ran from another repository eg, 
            # 'nix develop ../projects/other-project-flake'
            export REPO_ROOT="$(git rev-parse --show-toplevel)"
          '';
        };
      });

      formatter = eachSystem (pkgs:
        (treefmt-nix.lib.mkWrapper (pkgs) {
          projectRootFile = "flake.nix";

          programs.nixpkgs-fmt.enable = true;
          # Python linting/formatting
          programs.ruff.check = true;
          programs.ruff.format = true;
          # Python static typing checker
          programs.mypy = {
            enable = true;
            directories = {
              "wrapper" = {
                directory = ".";
                modules = [ "BetterOdooApiWrapper" ];
                extraPythonPackages = [ ];
              };
            };
          };
        }));


      # Run integration tests with;
      # nix run nixpkgs#nix-fast-build
      # [CI builds] nix run nixpkgs#nix-fast-build -- --no-nom
      checks = eachSystem (pkgs: {
        integration = pkgs.testers.runNixOSTest ({ ... }: {
          name = "better-odoo-api integration tests";
          nodes.machine = { pkgs, ... }: {
            services.odoo.enable = true;
            services.odoo.autoInit = true;
            services.odoo.autoInitExtraFlags = [
              "-i hr" # includes hr.employee model
            ];
            services.odoo.settings = {
              options.http_enable = true;
              options.http_interface = "127.0.0.1";
              # options.workers = 1; # Currently broken due to wrapping binary entrypoint "odoo"
            };
            environment.systemPackages = [
              (pkgs.python3.withPackages (ps: [
                ps.python-dotenv
                self.outputs.packages.${pkgs.system}.default
              ]))
            ];
          };

          testScript = ''
            machine.wait_for_unit("odoo.service")
            machine.wait_for_open_port(8069) # Default odoo port
            # Find tests in all files including integration tests, because we're in an integration environment.
            machine.succeed("""
              cd '${self}' \
              && ODOO_URL="http://127.0.0.1:8069" ODOO_DB="odoo" ODOO_USER="admin" ODOO_PASS="admin" python -m unittest discover -p '*.py'
            """)
          '';
        });
      });
    };
}
