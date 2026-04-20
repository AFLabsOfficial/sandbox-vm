{ pkgs, ... }:

let
  inherit (pkgs) stdenv lib;
  version = "2.1.114";

  # upstream ships platform-native binaries as separate npm packages under
  # @anthropic-ai/claude-code-<platform>; the wrapper package is just a
  # postinstall shim that copies the matching one into place
  sources = {
    "x86_64-linux" = {
      slug = "linux-x64";
      hash = "sha256-gejcdjRzKnWsvLzxJLfdjr+PeYdOR9tkCOL8owuJuf8=";
    };
    "aarch64-linux" = {
      slug = "linux-arm64";
      hash = "sha256-atThX6FuIJe0t7pQRd76ZIVCPd+AKfkLl1a48eLglQE=";
    };
    "x86_64-darwin" = {
      slug = "darwin-x64";
      hash = "sha256-1tUHaaE4AI8r7W+vS4wCKTH3OjDOxMRtSzyUt+LHhAs=";
    };
    "aarch64-darwin" = {
      slug = "darwin-arm64";
      hash = "sha256-Nx0I2PZgoLeI43c5O4rlyPgEQGDom3RO5pemV9V1vqg=";
    };
  };

  source =
    sources.${stdenv.hostPlatform.system}
      or (throw "claude-code: unsupported system ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "claude-code";
  inherit version;

  src = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@anthropic-ai/claude-code-${source.slug}/-/claude-code-${source.slug}-${version}.tgz";
    inherit (source) hash;
  };

  nativeBuildInputs = [
    pkgs.makeWrapper
  ] ++ lib.optionals stdenv.hostPlatform.isLinux [ pkgs.patchelf ];

  dontBuild = true;
  dontConfigure = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 claude $out/bin/claude
    runHook postInstall
  '';

  # NOTE:(@janezicmatej) upstream is a bun single-file-executable; the
  # embedded script payload sits at the tail of the ELF, so autoPatchelfHook's
  # section-layout changes corrupt it — only the interpreter can be rewritten
  postFixup = lib.optionalString stdenv.hostPlatform.isLinux ''
    patchelf --set-interpreter ${stdenv.cc.bintools.dynamicLinker} $out/bin/claude
  '' + ''
    wrapProgram $out/bin/claude \
      --set DISABLE_AUTOUPDATER 1 \
      --set-default FORCE_AUTOUPDATE_PLUGINS 1 \
      --set DISABLE_INSTALLATION_CHECKS 1 \
      --unset DEV \
      --prefix PATH : ${
        lib.makeBinPath (
          [
            pkgs.procps
          ]
          ++ lib.optionals stdenv.hostPlatform.isLinux [
            pkgs.bubblewrap
            pkgs.socat
          ]
        )
      }
  '';

  meta = {
    description = "Agentic coding tool that lives in your terminal, understands your codebase, and helps you code faster";
    homepage = "https://github.com/anthropics/claude-code";
    downloadPage = "https://www.npmjs.com/package/@anthropic-ai/claude-code";
    license = lib.licenses.unfree;
    mainProgram = "claude";
    platforms = lib.attrNames sources;
  };
}
