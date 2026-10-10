# Plasma Wallpaper: Smart Video Wallpaper Reborn (with native decode-cap plugin)
#
# Builds the wallpaper KPackage AND its native QML plugin
# (com.github.luisbocanegra.svwr -> DayNight + CappedVideoPlayer) as a single
# derivation, installed the Nix way:
#   - $out/share/plasma/wallpapers/<id>/          (the wallpaper, discovered by Plasma)
#   - $out/${qt6.qtQmlPrefix}/com/github/luisbocanegra.svwr/  (the QML module)
#
# The QML module lands on QT_QML_PLUGIN_PATH / NIXPKGS_QT6_QML_IMPORT_PATH
# automatically because it is installed into qt6's qml dir under the store.

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

stdenv.mkDerivation (finalAttrs: {
  pname = "plasma-smart-video-wallpaper-reborn";
  version = "2.16.0";

  src = src;

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    wrapQtAppsHook
  ];

  buildInputs = [
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
    gst_all_1.gst-libav
  ];

  cmakeFlags = [
    "-DBUILD_PLUGIN=ON"
    "-DINSTALL_WALLPAPER=ON"
    "-DPACKAGE_WALLPAPER=OFF"
    # Bake the GStreamer plugin dirs into the .so so CappedVideoPlayer can set
    # GST_PLUGIN_SYSTEM_PATH_1_0 before gst_init (plasmashell's env doesn't
    # carry it because this is a runtime-loaded QML plugin, not a wrapped binary).
    "-DGST_PLUGIN_PATH_1_0=${lib.makeSearchPath "lib/gstreamer-1.0" [ gst_all_1.gst-plugins-base gst_all_1.gst-plugins-good gst_all_1.gst-plugins-bad gst_all_1.gst-libav ]}"
  ];

  meta = with lib; {
    description = "Plasma 6 wallpaper plugin to play videos on your Desktop/Lock Screen";
    license = licenses.gpl2Plus;
    maintainers = [ ];
    platforms = platforms.linux;
  };
})
