from __future__ import annotations

import sys
import types
from contextlib import contextmanager


@contextmanager
def mlx_mel_filter_as_librosa():
    """Give Parakeet its sole Librosa function without bundling Librosa."""
    from mlx_audio.dsp import mel_filters

    previous = {
        name: sys.modules.get(name)
        for name in ("librosa", "librosa.filters")
    }
    filters = types.ModuleType("librosa.filters")

    def mel(*, sr, n_fft, n_mels, fmin=0, fmax=None, norm="slaney"):
        return mel_filters(
            sample_rate=sr,
            n_fft=n_fft,
            n_mels=n_mels,
            f_min=fmin,
            f_max=fmax,
            norm=norm,
            mel_scale="slaney",
            precise=True,
        )

    filters.mel = mel
    librosa = types.ModuleType("librosa")
    librosa.filters = filters
    sys.modules["librosa"] = librosa
    sys.modules["librosa.filters"] = filters
    try:
        yield
    finally:
        for name, module in previous.items():
            if module is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = module
