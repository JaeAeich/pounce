# Prebuilt, Developer ID-signed + notarized release zip (keeps the TCC grant stable across
# updates, unlike source builds). Template: not wired into the flake until a release exists.
# To enable, in flake.nix `packages`:  pounce-bin = pkgs.callPackage ./nix/pounce-bin.nix { };
# and bump `version` + `hash` per release (`nix store prefetch-file <url>`).
{
  lib,
  stdenvNoCC,
  fetchurl,
  unzip,
  makeWrapper,
}:

stdenvNoCC.mkDerivation rec {
  pname = "pounce-bin";
  version = "0.1.0";

  src = fetchurl {
    url = "https://github.com/jaeaeich/pounce/releases/download/v${version}/Pounce-${version}.zip";
    hash = lib.fakeHash;
  };

  nativeBuildInputs = [
    unzip
    makeWrapper
  ];
  sourceRoot = ".";
  # Never touch the signed bundle: stripping/patching would invalidate the signature.
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/Applications $out/bin
    cp -R Pounce.app $out/Applications/
    makeWrapper $out/Applications/Pounce.app/Contents/MacOS/Pounce $out/bin/pounce
    runHook postInstall
  '';

  meta = {
    description = "Keyboard-driven clicking, scrolling and window navigation for macOS (prebuilt)";
    homepage = "https://github.com/jaeaeich/pounce";
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "pounce";
  };
}
