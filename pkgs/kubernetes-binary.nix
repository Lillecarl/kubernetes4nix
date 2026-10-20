{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  version,
  hash,
  flavor,
  arch,
}:

let
  mainProgram = {
    client = "kubectl";
    server = "kube-apiserver";
    node = "kubelet";
  };
  platform = {
    amd64 = "x86_64-linux";
    arm64 = "aarch64-linux";
  };
in
stdenv.mkDerivation {
  pname = "kubernetes-${flavor}";
  inherit version;

  src = fetchurl {
    url = "https://dl.k8s.io/release/v${version}/kubernetes-${flavor}-linux-${arch}.tar.gz";
    inherit hash;
  };

  sourceRoot = "kubernetes";
  # The kubelet is dynamically linked against glibc (the others are static),
  # and NixOS has no /lib64/ld-linux-x86-64.so.2 to run it.
  nativeBuildInputs = [ autoPatchelfHook ];
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    find ${flavor}/bin -mindepth 1 -maxdepth 1 -type f -perm -u+x \
      -exec install -D -m 0755 {} -t $out/bin \;
    runHook postInstall
  '';

  meta = {
    description = "Official Kubernetes ${flavor} release archive, ${version}";
    homepage = "https://kubernetes.io";
    license = lib.licenses.asl20;
    mainProgram = mainProgram.${flavor};
    platforms = lib.optional (platform ? ${arch}) platform.${arch};
  };
}
