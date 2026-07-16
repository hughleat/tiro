"""Small compatibility surface for invoking the Tiro worker."""

from tiro_worker.common import API_VERSION
from tiro_worker.server import TiroHandler, main

__all__ = ["API_VERSION", "TiroHandler", "main"]
