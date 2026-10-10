{
  description = "Dev shell for plasma-smart-video-wallpaper-reborn native plugin (Qt6 + GStreamer + KF6)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      # Match the Plasma 6.6.6 / KF6 6.26 / Qt6 6.11 runtime found on this box.
      qt6 = pkgs.qt6;
      gst = pkgs.gst_all_1;
      kde = pkgs.kdePackages;
    in {
      devShells.${system}.default = pkgs.mkShell {
        nativeBuildInputs = [
          pkgs.cmake
          pkgs.ninja
          pkgs.pkg-config
          pkgs.gcc
          pkgs.gnumake
        ];

        buildInputs = [
          # Qt6 (QML module authoring + Multimedia for the custom sink)
          qt6.qtbase
          qt6.qtdeclarative
          qt6.qtmultimedia
          qt6.qttools          # moc, etc. (qmake-adjacent tooling)
          qt6.wrapQtAppsHook

          # GStreamer (decode → videoscale → capsfilter pipeline)
          gst.gstreamer
          gst.gst-plugins-base
          gst.gst-plugins-good
          gst.gst-plugins-bad
          gst.gst-libav

          # KDE Frameworks / Plasma (matches KNightTime + KCMUtils deps)
          kde.extra-cmake-modules
          kde.kcoreaddons
          kde.knighttime
          kde.kcmutils
          kde.kconfig
          kde.ki18n
          kde.kconfigwidgets
        ];

        # Let pkg-config (via nix's pkg-config wrapper) find all the dev packages.
        shellHook = ''
          echo "plasma-smart-video-wallpaper-reborn dev shell"
          echo "  Qt6: $(pkg-config --modversion Qt6Core 2>/dev/null || echo n/a)"
          echo "  GStreamer: $(pkg-config --modversion gstreamer-1.0 2>/dev/null || echo n/a)"
          echo "  build: cmake -B build -G Ninja && cmake --build build"
        '';
      };
    };
}
