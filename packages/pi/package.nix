{ pkgs, ... }:

let
  inherit (pkgs) stdenv lib;
  version = "0.84.4";

  # upstream ships platform-native binaries as github release assets; the npm
  # package is a plain node package that needs a node runtime, the release
  # tarballs are bun single-file-executables that don't
  sources = {
    "x86_64-linux" = {
      slug = "linux-x64";
      hash = "sha256-GL5WViEn4DKPZBFxwCgKNFYpm7X5XjOZmN3CvyXj9/4=";
    };
    "aarch64-linux" = {
      slug = "linux-arm64";
      hash = "sha256-0/A4WGz8rax5Mgktcf4BBTs/fv2LbcpXOvzcv6pv2zA=";
    };
    "x86_64-darwin" = {
      slug = "darwin-x64";
      hash = "sha256-nfYiKUuiPVwhzZ5RnynqhM84ueJil6wYLgkHXKOn2Nw=";
    };
    "aarch64-darwin" = {
      slug = "darwin-arm64";
      hash = "sha256-FCZ70MrUK2oVtZVWjsnI4SsZxzC7DAs0l1EtFIvwh8A=";
    };
  };

  source =
    sources.${stdenv.hostPlatform.system}
      or (throw "pi: unsupported system ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "pi";
  inherit version;

  src = pkgs.fetchzip {
    url = "https://github.com/earendil-works/pi/releases/download/v${version}/pi-${source.slug}.tar.gz";
    inherit (source) hash;
  };

  nativeBuildInputs = [
    pkgs.makeWrapper
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [ pkgs.patchelf ];

  dontBuild = true;
  dontConfigure = true;
  dontStrip = true;

  # NOTE:(@janezicmatej) pi resolves its shipped assets (theme/, export-html/,
  # package.json, photon_rs_bg.wasm, the clipboard native module) relative to
  # dirname(process.execPath), so the whole tree has to stay next to the
  # binary — $out/bin/pi is a wrapper, not a copy
  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib
    cp -r . $out/lib/pi
    chmod +x $out/lib/pi/pi
    runHook postInstall
  '';

  # NOTE:(@janezicmatej) upstream is a bun single-file-executable; the
  # embedded script payload sits at the tail of the ELF, so autoPatchelfHook's
  # section-layout changes corrupt it — only the interpreter can be rewritten.
  # the napi .node modules are dlopened by that binary, which has no rpath of
  # its own, so they need one for libgcc_s (glibc comes from the interpreter's
  # default search path)
  postFixup =
    lib.optionalString stdenv.hostPlatform.isLinux ''
      patchelf --set-interpreter ${stdenv.cc.bintools.dynamicLinker} $out/lib/pi/pi

      find $out/lib/pi -name '*.node' -type f | while read -r mod; do
        chmod u+w "$mod"
        patchelf --set-rpath ${lib.makeLibraryPath [ stdenv.cc.cc.lib ]} "$mod"
      done
    ''
    + ''
      # NOTE:(@janezicmatej) pi downloads fd and rg from github into its config
      # dir when neither is on PATH, so surface them from the store instead.
      # PI_SKIP_VERSION_CHECK suppresses the pi.dev latest-version nag — the
      # store path can't update itself; unset it to get the check back.
      # nodejs is suffixed, not prefixed: `pi install` shells out to npm for
      # both npm: and git: sources, but a node the user put on PATH for project
      # work must keep winning over ours
      makeWrapper $out/lib/pi/pi $out/bin/pi \
        --set-default PI_SKIP_VERSION_CHECK 1 \
        --prefix PATH : ${
          lib.makeBinPath [
            pkgs.ripgrep
            pkgs.fd
          ]
        } \
        --suffix PATH : ${lib.makeBinPath [ pkgs.nodejs ]}
    '';

  meta = {
    description = "Minimal, aggressively extensible coding agent harness";
    homepage = "https://pi.dev";
    downloadPage = "https://github.com/earendil-works/pi/releases";
    license = lib.licenses.mit;
    mainProgram = "pi";
    platforms = lib.attrNames sources;
  };
}
