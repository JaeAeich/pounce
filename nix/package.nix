{
  lib,
  swiftPackages,
  swift,
  swiftpm,
  makeWrapper,
  apple-sdk_26,
  # release-please bumps version.txt; the flake passes the git revision.
  version ? lib.strings.trim (builtins.readFile ../version.txt),
  commit ? "unknown",
}:

swiftPackages.stdenv.mkDerivation {
  pname = "pounce";
  inherit version;

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Package.swift
      ../Sources
      ../Resources
      ../Tests # declared in Package.swift
    ];
  };

  nativeBuildInputs = [
    swift
    swiftpm
    makeWrapper
  ];
  buildInputs = [ apple-sdk_26 ];

  # nixpkgs' Darwin swiftpm lacks swiftpm-testing-helper, so swift-testing can't run in the
  # sandbox. Tests run with the host toolchain instead: scripts/test.sh.
  doCheck = false;

  # swiftpm's setup hook builds `-c release`; we only need to assemble the bundle.
  installPhase = ''
    runHook preInstall

    app=$out/Applications/Pounce.app
    mkdir -p $app/Contents/MacOS $app/Contents/Resources $out/bin
    cp "$(swiftpmBinPath)/Pounce" $app/Contents/MacOS/Pounce
    cp Resources/AppIcon.icns $app/Contents/Resources/
    substitute Resources/Info.plist $app/Contents/Info.plist \
      --replace-fail @VERSION@ ${version} \
      --replace-fail @BUILD@ ${version} \
      --replace-fail @COMMIT@ ${commit}
    # Drop rpaths into the build toolchain (/nix/store/...-swift): the OS ships the Swift runtime,
    # and they would otherwise keep the whole toolchain in the closure.
    for rp in $(otool -l $app/Contents/MacOS/Pounce | awk '/cmd LC_RPATH/ {getline; getline; print $2}'); do
      case "$rp" in /nix/store/*) install_name_tool -delete_rpath "$rp" $app/Contents/MacOS/Pounce ;; esac
    done
    # exec (not symlink) so Bundle.main resolves to the .app
    makeWrapper $app/Contents/MacOS/Pounce $out/bin/pounce

    runHook postInstall
  '';

  meta = {
    description = "Keyboard-driven clicking, scrolling and window navigation for macOS";
    platforms = lib.platforms.darwin;
    mainProgram = "pounce";
    license = lib.licenses.mit;
  };
}
