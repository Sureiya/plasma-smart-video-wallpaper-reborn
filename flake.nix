{
  description = "plasma-smart-video-wallpaper-reborn: dev shell + package + NixOS module";

  inputs = {
    # Pin to the SAME nixpkgs rev as the system's /etc/nixos/flake.lock so the
    # native .so links against the exact Qt/KF6 the running plasmashell uses
    # (otherwise Qt private-API symbols mismatch and the module fails to load).
    nixpkgs.url = "github:NixOS/nixpkgs/8f0500b9660505dc3cb647775fe9a978a74b5283";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      qt6 = pkgs.qt6;
      gst = pkgs.gst_all_1;
      kde = pkgs.kdePackages;

      # The wallpaper + native plugin, built from THIS checkout.
      wallpaper = pkgs.callPackage ./default.nix {
        src = pkgs.lib.cleanSource ./.;
        wrapQtAppsHook = qt6.wrapQtAppsHook;
      };

    in {
      packages.${system} = {
        default = wallpaper;
        wallpaper = wallpaper;
      };

      devShells.${system}.default = pkgs.mkShell {
        nativeBuildInputs = [
          pkgs.cmake
          pkgs.ninja
          pkgs.pkg-config
          pkgs.gcc
          pkgs.gnumake
        ];

        buildInputs = [
          qt6.qtbase
          qt6.qtdeclarative
          qt6.qtmultimedia
          qt6.qttools
          qt6.wrapQtAppsHook
          gst.gstreamer
          gst.gst-plugins-base
          gst.gst-plugins-good
          gst.gst-plugins-bad
          gst.gst-libav
          kde.extra-cmake-modules
          kde.kcoreaddons
          kde.knighttime
          kde.kcmutils
          kde.kconfig
          kde.ki18n
          kde.kconfigwidgets
        ];

        shellHook = ''
          echo "plasma-smart-video-wallpaper-reborn dev shell"
          echo "  Qt6: $(pkg-config --modversion Qt6Core 2>/dev/null || echo n/a)"
          echo "  GStreamer: $(pkg-config --modversion gstreamer-1.0 2>/dev/null || echo n/a)"
          echo "  build: cmake -B build -G Ninja && cmake --build build"
        '';
      };

      # NixOS module: adds the wallpaper package to the system so both the
      # wallpaper (share/plasma/wallpapers) and its QML plugin are on the
      # import paths, then lets the user install it via KPackage.
      nixosModules.default = { config, lib, ... }:
        let cfg = config.plasma-smart-video-wallpaper-reborn;
        in {
          options.plasma-smart-video-wallpaper-reborn.enable = lib.mkEnableOption "Smart Video Wallpaper Reborn";

          config = lib.mkIf cfg.enable {
            environment.systemPackages = [ wallpaper ];

            # Ensure the QML module is in the session's import path. The native
            # plugin installs to ${wallpaper}/lib/qt-6/qml/..., which matches Qt6's
            # module prefix and lands on NIXPKGS_QT6_QML_IMPORT_PATH when the
            # package is in systemPackages.
            environment.sessionVariables.QML_IMPORT_PATH = [
              "${wallpaper}/lib/qt-6/qml"
            ];
          };
        };
    };
}
