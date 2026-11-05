{
  description = "Docling Serve OCI image built with Nix dockerTools";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/02c087f3fe673c9e317f206a627cb6b910336dbe";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    docling-serve-src = {
      url = "github:docling-project/docling-serve/7eebd99b990113e1e3d67cba5ad59531ee07ed3c";
      flake = false;
    };
  };

  outputs =
    {
      nixpkgs,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
      docling-serve-src,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = nixpkgs.lib;
      version = "1.38.0";
      revision = "7eebd99b990113e1e3d67cba5ad59531ee07ed3c";
      python = pkgs.python313;

      workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = docling-serve-src; };
      deps = workspace.deps.default // { docling-serve = [ "cpu" ]; };
      overlay = workspace.mkPyprojectOverlay {
        sourcePreference = "wheel";
        dependencies = deps;
      };

      runtimeOverlay = final: prev: {
        # TorchVision's wheel needs libtorch on the patchelf search path.
        torchvision = prev.torchvision.overrideAttrs (old: {
          buildInputs = (old.buildInputs or [ ]) ++ [ final.torch ];
          preInstall = (old.preInstall or "") + ''
            addAutoPatchelfSearchPath "${final.torch}/${python.sitePackages}/torch"
          '';
        });

        # Keep RapidOCR's bundled ONNX weights out; runtime downloads use writable /data.
        rapidocr = prev.rapidocr.overrideAttrs (old: {
          postInstall = (old.postInstall or "") + ''
            substituteInPlace "$out/${python.sitePackages}/rapidocr/config.yaml" \
              --replace-fail 'model_root_dir: null' 'model_root_dir: /data/rapidocr-models'
            find "$out/${python.sitePackages}/rapidocr/models" -type f -name '*.onnx' -delete
          '';
        });
      };

      pythonSet = (pkgs.callPackage pyproject-nix.build.packages { inherit python; })
        .overrideScope (lib.composeManyExtensions [
          pyproject-build-systems.overlays.wheel
          overlay
          runtimeOverlay
        ]);
      pythonEnv = pythonSet.mkVirtualEnv "docling-serve-env" deps;

      pythonImportCheck = pkgs.runCommand "docling-serve-import-check" { } ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        ${pythonEnv}/bin/python - <<'PY'
import importlib.metadata as metadata
import importlib.util

assert metadata.version("docling-serve") == "1.38.0"
for name in ("docling_core", "docling_jobkit", "docling", "docling_serve", "torch", "torchvision"):
    assert importlib.util.find_spec(name), name
assert importlib.util.find_spec("saxonche") is None
import docling_serve.app
print("Docling Serve imports; SaxonC is not included")
PY
        touch "$out"
      '';

      modelWeightsCheck = pkgs.runCommand "docling-serve-model-weights-check" { } ''
        ${pythonEnv}/bin/python - <<'PY'
import importlib.util
import os
from pathlib import Path
import sys

rapidocr = Path(importlib.util.find_spec("rapidocr").origin).resolve().parent
models = rapidocr / "models"
assert not [path for path in models.rglob("*") if path.is_file() and path.suffix.lower() == ".onnx"]
config = (rapidocr / "config.yaml").read_text()
assert "model_root_dir: /data/rapidocr-models" in config

# shortcut: checks common model suffixes; extend this set if dependencies add another weight format.
model_suffixes = {".onnx", ".safetensors", ".pt", ".pth", ".bin", ".pdmodel", ".pdiparams", ".tflite"}
weights = []
for directory, _, files in os.walk(sys.prefix, followlinks=True):
    for name in files:
        path = Path(directory) / name
        if path.suffix.lower() in model_suffixes and path.is_file():
            if path.suffix.lower() == ".onnx" or path.stat().st_size > 1_000_000:
                weights.append(str(path))
assert not weights, f"model weights found in Python environment: {weights}"
print("No model weights bundled; RapidOCR runtime cache points to /data/rapidocr-models")
PY
        touch "$out"
      '';

      serviceHealthCheck = pkgs.runCommand "docling-serve-health-check" { } ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME" "$TMPDIR/docling" "$TMPDIR/hf"
        export HF_HOME="$TMPDIR/hf"
        export DOCLING_SERVE_LOAD_MODELS_AT_BOOT=false
        export DOCLING_SERVE_ENG_LOC_NUM_WORKERS=1
        export DOCLING_SERVE_SCRATCH_PATH="$TMPDIR/docling"
        export HF_HUB_OFFLINE=1
        export TRANSFORMERS_OFFLINE=1
        ${pythonEnv}/bin/python - <<'PY'
import os, subprocess, time, urllib.error, urllib.request

port = 5099
log_path = os.path.join(os.environ["TMPDIR"], "server.log")
with open(log_path, "w+") as log:
    proc = subprocess.Popen(
        ["${pythonEnv}/bin/docling-serve", "run", "--host", "127.0.0.1", "--port", str(port)],
        env=os.environ.copy(), stdout=log, stderr=subprocess.STDOUT,
    )
    try:
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                raise RuntimeError(f"server exited early: {proc.returncode}")
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as response:
                    assert response.status == 200
                break
            except urllib.error.URLError:
                time.sleep(0.5)
        else:
            raise TimeoutError("server did not become healthy")
        for path in ("/ready", "/readyz", "/livez"):
            with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=2) as response:
                assert response.status == 200, (path, response.status)
    except Exception as error:
        log.flush()
        log.seek(0)
        raise RuntimeError(f"{error}\n{log.read()[-8000:]}") from error
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
print("Health, readiness, and liveness pass with model loading disabled and HF offline")
PY
        touch "$out"
      '';

      image = pkgs.dockerTools.buildLayeredImage {
        name = "docling-serve";
        tag = version;
        contents = [
          pythonEnv
          pkgs.dockerTools.fakeNss
          pkgs.cacert
        ];

        config = {
          User = "10001:10001";
          WorkingDir = "/data";
          Entrypoint = [ "${pythonEnv}/bin/docling-serve" ];
          Cmd = [ "run" "--host" "0.0.0.0" "--port" "5001" ];
          Env = [
            "PATH=${pythonEnv}/bin"
            "HOME=/data"
            "TMPDIR=/tmp"
            "HF_HOME=/data/huggingface"
            "PYTHONUNBUFFERED=1"
            "PYTHONDONTWRITEBYTECODE=1"
            "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            "REQUESTS_CA_BUNDLE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
          ];
          ExposedPorts = { "5001/tcp" = { }; };
          Volumes = { "/data" = { }; };
          Healthcheck = {
            Test = [
              "CMD"
              "${pythonEnv}/bin/python"
              "-c"
              "import urllib.request; urllib.request.urlopen('http://127.0.0.1:5001/ready', timeout=2)"
            ];
            Interval = 30 * 1000000000;
            Timeout = 5 * 1000000000;
            StartPeriod = 30 * 60 * 1000000000;
            Retries = 3;
          };
          Labels = {
            "org.opencontainers.image.title" = "Docling Serve";
            "org.opencontainers.image.description" = "CPU-only Docling document conversion API";
            "org.opencontainers.image.source" = "https://github.com/docling-project/docling-serve";
            "org.opencontainers.image.version" = version;
            "org.opencontainers.image.revision" = revision;
            "org.opencontainers.image.licenses" = "MIT";
          };
        };

        fakeRootCommands = ''
          mkdir -p ./data/huggingface ./data/rapidocr-models ./tmp
          chown -R 10001:10001 ./data
          chmod 0700 ./data
          chmod 1777 ./tmp
        '';
      };
    in
    {
      packages.${system} = {
        inherit image;
        default = image;
      };

      checks.${system} = {
        inherit image;
        python-import = pythonImportCheck;
        service-health = serviceHealthCheck;
        model-weights-excluded = modelWeightsCheck;
      };
    };
}
