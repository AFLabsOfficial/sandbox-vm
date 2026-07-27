{ pkgs, ... }:

let
  inherit (pkgs) stdenv lib;
  version = "0.145.0";

  # upstream ships platform-native binaries via versioned tags on the same
  # @openai/codex npm package (the @openai/codex-<slug> aliases all resolve
  # to the same tarball at version <version>-<slug>); the tarball contains
  # the codex binary under vendor/<triple>/bin/codex plus bundled rg under
  # vendor/<triple>/codex-path and bwrap under vendor/<triple>/codex-resources
  sources = {
    "x86_64-linux" = {
      slug = "linux-x64";
      triple = "x86_64-unknown-linux-musl";
      hash = "sha256-ZKJMWupW3X23BTGP1meEQJVOhBGfT/JY882PtiawBpU=";
    };
    "aarch64-linux" = {
      slug = "linux-arm64";
      triple = "aarch64-unknown-linux-musl";
      hash = "sha256-PktRwNYUPqHi9/z0Kuy1OExO56E3zfMOZ82PqQbvQCM=";
    };
    "x86_64-darwin" = {
      slug = "darwin-x64";
      triple = "x86_64-apple-darwin";
      hash = "sha256-GXZ2oFLDWoZEqgRNbl8H0J4n+pjFP6P3PmqJ8+VQ+7o=";
    };
    "aarch64-darwin" = {
      slug = "darwin-arm64";
      triple = "aarch64-apple-darwin";
      hash = "sha256-dZ8Q1LTI34qQ5eVDLrFnPGQyx/cev7UAReVow7DmDw4=";
    };
  };

  source =
    sources.${stdenv.hostPlatform.system}
      or (throw "codex: unsupported system ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "codex";
  inherit version;

  src = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@openai/codex/-/codex-${version}-${source.slug}.tgz";
    inherit (source) hash;
  };

  nativeBuildInputs = [ pkgs.makeWrapper ];

  dontBuild = true;
  dontConfigure = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 vendor/${source.triple}/bin/codex $out/bin/codex
    runHook postInstall
  '';

  # NOTE:(@janezicmatej) codex is a statically-linked musl ELF on linux and
  # a self-contained mach-o on darwin, so there is nothing to patchelf; the
  # wrapper only exists to surface the tools codex expects on PATH (ripgrep
  # for built-in search, bubblewrap for sandboxed exec on linux)
  postFixup = ''
    wrapProgram $out/bin/codex \
      --prefix PATH : ${
        lib.makeBinPath ([ pkgs.ripgrep ] ++ lib.optionals stdenv.hostPlatform.isLinux [ pkgs.bubblewrap ])
      }
  '';

  meta = {
    description = "Codex CLI, a coding agent from OpenAI that runs locally on your computer";
    homepage = "https://github.com/openai/codex";
    downloadPage = "https://www.npmjs.com/package/@openai/codex";
    license = lib.licenses.asl20;
    mainProgram = "codex";
    platforms = lib.attrNames sources;
  };
}
