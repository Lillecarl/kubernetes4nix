{
  lib,
  buildGoModule,
  fetchFromGitHub,
  installShellFiles,
  makeWrapper,
  rsync,
  runtimeShell,
  which,
  version,
  hash,
  components ? [
    "cmd/kube-apiserver"
    "cmd/kube-controller-manager"
    "cmd/kube-scheduler"
    "cmd/kubelet"
    "cmd/kube-proxy"
    "cmd/kubeadm"
    "cmd/kubectl"
  ],
}:

buildGoModule (finalAttrs: {
  pname = "kubernetes";
  inherit version;

  src = fetchFromGitHub {
    owner = "kubernetes";
    repo = "kubernetes";
    tag = "v${finalAttrs.version}";
    inherit hash;
  };

  vendorHash = null;
  doCheck = false;

  nativeBuildInputs = [
    installShellFiles
    makeWrapper
    rsync
    which
  ];

  outputs = [
    "out"
    "man"
    "pause"
  ];

  patches = [ ./fixup-addonmanager-lib-path.patch ];

  env.WHAT = toString components;

  buildPhase = ''
    runHook preBuild
    substituteInPlace "hack/update-generated-docs.sh" \
      --replace "make" "make SHELL=${runtimeShell}"
    patchShebangs ./hack ./cluster/addons/addon-manager
    make "SHELL=${runtimeShell}" "WHAT=$WHAT"
    ./hack/update-generated-docs.sh
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    for p in $WHAT; do
      install -D _output/local/go/bin/''${p##*/} -t $out/bin
    done

    cc build/pause/linux/pause.c -o pause
    install -D pause -t $pause/bin

    installManPage docs/man/man1/*.[1-9]

    substitute cluster/addons/addon-manager/kube-addons-main.sh $out/bin/kube-addons \
      --subst-var out
    chmod +x $out/bin/kube-addons
    wrapProgram $out/bin/kube-addons --set "KUBECTL_BIN" "$out/bin/kubectl"

    cp cluster/addons/addon-manager/kube-addons.sh $out/bin/kube-addons-lib.sh

    installShellCompletion --cmd kubeadm \
      --bash <($out/bin/kubeadm completion bash) \
      --zsh <($out/bin/kubeadm completion zsh)
    runHook postInstall
  '';

  meta = {
    description = "Production-Grade Container Scheduling and Management";
    homepage = "https://kubernetes.io";
    license = lib.licenses.asl20;
    mainProgram = "kubectl";
    platforms = lib.platforms.linux;
  };
})
