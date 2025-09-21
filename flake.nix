{
  description = "VoxVibe on NixOS (HM shared module, CUDA, large-v3)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, home-manager, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system:
          f (import nixpkgs {
            inherit system;
            config = {
              cudaSupport = true; # turn on CUDA support globally
              allowUnfree = true; # allow unfree packages like CUDA
            };
            overlays = [ self.overlays.default ];
          }));
    in {
      overlays.default = final: prev:
        let
          # --- Build the GNOME extension from repo:/extension and expose its UUID
          voxvibe-gnome-extension = final.stdenvNoCC.mkDerivation {
            pname = "voxvibe-gnome-extension";
            version = "git-2025-09-19";
            src = final.fetchFromGitHub {
              owner = "jdcockrill";
              repo = "voxvibe";
              rev = "main";
              sha256 = "sha256-uf0c0eJiLEYEijHJiutfZzVg6cnZVBwBDKtpcY8H4dI=";
            };

            nativeBuildInputs = [ final.jq ];

            # Don't run the Makefile, just copy the extension directory
            dontBuild = true;

            installPhase = ''
              set -euo pipefail
              cd extension
              uuid="$(jq -r .uuid metadata.json)"
              install -Dm644 * -t "$out/share/gnome-shell/extensions/$uuid/"
              mkdir -p "$out/nix-support"
              printf "%s" "$uuid" > "$out/nix-support/uuid"
            '';
          };

          # --- Build VoxVibe Python app (repo:/app) with faster-whisper + CUDA CTranslate2
          voxvibe = final.python312Packages.buildPythonApplication {
            pname = "voxvibe";
            version = "git-2025-09-19";
            src = final.fetchFromGitHub {
              owner = "jdcockrill";
              repo = "voxvibe";
              rev = "main";
              sha256 = "sha256-uf0c0eJiLEYEijHJiutfZzVg6cnZVBwBDKtpcY8H4dI=";
            };

            # The Python sources live under app/
            sourceRoot = "source/app";

            # This IS a pyproject-based package
            pyproject = true;

            # Use the correct build system (hatchling, as specified in pyproject.toml)
            build-system = with final.python312Packages; [ hatchling ];

            # Dependencies with CUDA-enabled ctranslate2
            dependencies = with final.python312Packages; [
              (faster-whisper.override {
                ctranslate2 = final.ctranslate2.override { withCUDA = true; };
              })
              sounddevice
              soundfile
              pyqt6
              qt-material
              pynput
              numpy
              # Note: mistralai and litellm may need to be packaged separately if not available
              # mistralai
              # litellm
            ];

            nativeBuildInputs = [ final.makeWrapper ];

            # Make sure CUDA & cuDNN are visible at runtime
            postInstall = ''
              wrapProgram "$out/bin/voxvibe" \
                --prefix LD_LIBRARY_PATH : ${final.cudaPackages.cudatoolkit}/lib:${final.cudaPackages.cudnn}/lib
            '';
          };
        in { inherit voxvibe-gnome-extension voxvibe; };

      # --- Home-Manager module (shared)
      homeManagerModules.voxvibe = { config, lib, pkgs, ... }:
        let
          cfg = config.programs.voxvibe;
          uuid = lib.removeSuffix "\n" (builtins.readFile
            "${pkgs.voxvibe-gnome-extension}/nix-support/uuid");
        in {
          options.programs.voxvibe = {
            enable = lib.mkEnableOption "VoxVibe dictation";
            package =
              lib.mkPackageOption pkgs "voxvibe" { default = [ "voxvibe" ]; };
            model = lib.mkOption {
              type = lib.types.str;
              default = "large-v3";
            }; # best accuracy
            device = lib.mkOption {
              type = lib.types.enum [ "auto" "cpu" "cuda" ];
              default = "cuda";
            };
            computeType = lib.mkOption {
              type =
                lib.types.enum [ "auto" "int8" "int16" "float16" "float32" ];
              default = "float16";
            };
            hotkey = lib.mkOption {
              type = lib.types.str;
              default = "<Super>h";
            }; # Win+H analogue
            postProcess = lib.mkOption {
              type = lib.types.bool;
              default = false;
            }; # off by default
          };

          config = lib.mkIf cfg.enable {
            home.packages =
              [ cfg.package pkgs.voxvibe-gnome-extension pkgs.portaudio ];

            # VoxVibe config (~/.config/voxvibe/config.toml)
            xdg.configFile."voxvibe/config.toml".text = ''
              [transcription]
              model = "${cfg.model}"
              language = "auto"
              device = "${cfg.device}"
              compute_type = "${cfg.computeType}"

              [window_manager]
              strategy = "dbus"     # use GNOME extension for focus & paste

              [hotkeys]
              strategy = "dbus"     # global hotkeys via GNOME extension

              [ui]
              show_notifications = true
              minimize_to_tray = true

              [post_processing]
              enabled = ${if cfg.postProcess then "true" else "false"}
              model = "openai/gpt-4.1-mini"
              temperature = 0.3
            '';

            # Install + enable the GNOME extension (uses UUID from metadata.json)
            dconf.enable = true;
            dconf.settings."org/gnome/shell" = {
              disable-user-extensions = false;
              enabled-extensions = lib.mkAfter [ uuid ];
            };

            # User service: start VoxVibe with your session
            systemd.user.services.voxvibe = {
              Unit = {
                Description = "VoxVibe dictation service";
                PartOf = [ "graphical-session.target" ];
                After = [ "graphical-session.target" ];
              };
              Service = {
                ExecStart = "${cfg.package}/bin/voxvibe";
                Restart = "on-failure";
                # Make CUDA libs visible (matches our wrapper; duplicated here for robustness)
                Environment = [
                  "LD_LIBRARY_PATH=${pkgs.cudaPackages.cudatoolkit}/lib:${pkgs.cudaPackages.cudnn}/lib"
                ];
              };
              Install = { WantedBy = [ "graphical-session.target" ]; };
            };
          };
        };

      # Optional NixOS module that wires in HM shared module + CUDA
      nixosModules.voxvibe = { config, lib, ... }: {
        options.services.voxvibe.enable = lib.mkEnableOption
          "system-wide VoxVibe plumbing (via HM shared module)";
        config = lib.mkIf config.services.voxvibe.enable {
          programs.dconf.enable = true;
          # Ensure CUDA infra is on; you still need your NVIDIA driver configured normally.
          nixpkgs.config.cudaSupport = true;

          # Load our HM module for every HM user (they can flip programs.voxvibe.enable=true)
          imports = [ home-manager.nixosModules.default ];
          home-manager.sharedModules = [ self.homeManagerModules.voxvibe ];
        };
      };

      # make packages visible via `nix build .#voxvibe`
      packages = forAllSystems (pkgs: {
        inherit (pkgs) voxvibe voxvibe-gnome-extension;
        default = pkgs.voxvibe;
      });
    };
}
