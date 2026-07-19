"""PyInstaller entry point that relocates all mutable Tiro worker state."""

from __future__ import annotations

import os
import sys
from pathlib import Path

if not getattr(sys, "frozen", False):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tiro_worker import common, server


def configure_paths() -> None:
    data_root = Path(os.environ["TIRO_DATA_DIR"]).expanduser()
    model_root = Path(os.environ["TIRO_MODEL_DIR"]).expanduser()
    common._reject_symbolic_link(data_root)
    common._reject_symbolic_link(model_root)
    data_dir = data_root.resolve()
    model_dir = model_root.resolve()

    common.configure_paths(data_dir, model_dir)
    os.environ["HF_HOME"] = str(model_dir)
    common.ensure_private_paths()


def run_self_test() -> None:
    import importlib.util

    import mlx.core as mx
    import mlx_audio.stt.models.qwen3_asr  # noqa: F401

    from tiro_worker.parakeet_compat import mlx_mel_filter_as_librosa

    with mlx_mel_filter_as_librosa():
        import parakeet_mlx  # noqa: F401

    total = mx.array([1, 2, 3]).sum()
    mx.eval(total)
    if total.item() != 6:
        raise RuntimeError("MLX returned an unexpected self-test result")
    if getattr(sys, "frozen", False):
        excluded = ("librosa", "numba", "llvmlite", "scipy", "sklearn")
        present = [name for name in excluded if importlib.util.find_spec(name) is not None]
        if present:
            raise RuntimeError("Excluded release dependencies are present: " + ", ".join(present))
    print("Tiro ML runtime self-test passed")


if __name__ == "__main__":
    configure_paths()
    if sys.argv[1:] == ["--self-test"]:
        run_self_test()
    elif sys.argv[1:]:
        raise SystemExit("unknown worker argument")
    else:
        server.main()
