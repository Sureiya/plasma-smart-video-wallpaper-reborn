# Plasma Wallpaper: Smart Video Wallpaper Reborn (with native decode-cap plugin)
#
# Split into TWO derivations so QML/JS edits never recompile the C++ plugin:
#   1. pluginSo  — the native QML plugin (.so), cached by C++ source only.
#   2. wallpaper — the QML/JS KPackage, which copies in the prebuilt .so.
#
# Output layout (the Nix way):
#   - $out/share/plasma/wallpapers/<id>/          (wallpaper, discovered by Plasma)
#   - $out/lib/qt-6/qml/com/github/luisbocanegra.svwr/  (QML module)

{ lib
, stdenv
, cmake
, ninja
, pkg-config
, wrapQtAppsHook
, qt6
, kdePackages
, gst_all_1
, src
}:

let
  rel = p: lib.removePrefix (toString src + "/") (toString p);

  # Only the files that affect the native .so build: top-level CMakeLists.txt,
  # the plugin/ dir, and package/metadata.json (read by CMake for id/version).
  pluginSrc = lib.cleanSourceWith {
    inherit src;
    filter = p: t:
      let r = rel p; in
      r == "" || r == "CMakeLists.txt"
      || r == "plugin" || lib.hasPrefix "plugin/" r
      || r == "package" || r == "package/metadata.json";
  };

  # Only the files that affect the wallpaper KPackage + translations.
  wallpaperSrc = lib.cleanSourceWith {
    inherit src;
    filter = p: t:
      let r = rel p; in
      r == "" || r == "CMakeLists.txt"
      || r == "package" || lib.hasPrefix "package/" r
      || r == "translate" || lib.hasPrefix "translate/" r;
  };

  gstPath = lib.makeSearchPath "lib/gstreamer-1.0" [
    (lib.getLib gst_all_1.gstreamer)
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-good
    gst_all_1.gst-plugins-bad
    gst_all_1.gst-plugins-ugly
    gst_all_1.gst-libav
  ];

  deps = [
    qt6.qtbase
    qt6.qtdeclarative
    qt6.qtmultimedia
    kdePackages.kcoreaddons
    kdePackages.knighttime
    kdePackages.kcmutils
    kdePackages.kconfig
    kdePackages.ki18n
    kdePackages.kconfigwidgets
    kdePackages.libplasma
    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-good
    gst_all_1.gst-plugins-bad
    gst_all_1.gst-plugins-ugly
    gst_all_1.gst-libav
  ];

  pluginSo = stdenv.mkDerivation {
    pname = "plasma-wallpaper-svw-plugin";
    version = "2.16.0";
    src = pluginSrc;
    nativeBuildInputs = [ cmake ninja pkg-config wrapQtAppsHook ];
    buildInputs = deps;
    cmakeFlags = [
      "-DBUILD_PLUGIN=ON"
      "-DINSTALL_WALLPAPER=OFF"
      "-DPACKAGE_WALLPAPER=OFF"
      # Bake the GStreamer plugin dirs into the .so so CappedVideoPlayer can set
      # GST_PLUGIN_SYSTEM_PATH_1_0 before gst_init (plasmashell's env doesn't
      # carry it because this is a runtime-loaded QML plugin, not a wrapped binary).
      "-DGST_PLUGIN_PATH_1_0=${gstPath}"
    ];
  };

  wallpaper = stdenv.mkDerivation {
    pname = "plasma-smart-video-wallpaper-reborn";
    version = "2.16.0";
    src = wallpaperSrc;
    nativeBuildInputs = [ cmake ninja pkg-config wrapQtAppsHook ];
    buildInputs = deps;
    cmakeFlags = [
      "-DBUILD_PLUGIN=OFF"
      "-DINSTALL_WALLPAPER=ON"
      "-DPACKAGE_WALLPAPER=OFF"
    ];
    # Copy the prebuilt .so into the qml dir and restore the exec bit that
    # plasma_install_package drops on tools/*.sh.
    postInstall = ''
      mkdir -p "$out/lib/qt-6/qml/com/github/luisbocanegra/svwr"
      cp -r ${pluginSo}/lib/qt-6/qml/com/github/luisbocanegra/svwr/. "$out/lib/qt-6/qml/com/github/luisbocanegra/svwr/"
      chmod +x "$out/share/plasma/wallpapers/luisbocanegra.smart.video.wallpaper.reborn/contents/ui/tools/"*.sh 2>/dev/null || true
    '';
    meta = with lib; {
      description = "Plasma 6 wallpaper plugin to play videos on your Desktop/Lock Screen";
      license = licenses.gpl2Plus;
      maintainers = [ ];
      platforms = platforms.linux;
    };
  };
in
wallpaper
