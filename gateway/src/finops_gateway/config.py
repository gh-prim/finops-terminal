"""Runtime settings pushed by the app (Settings window) through the `config` service."""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass
class Config:
    edgar_contact: str = os.environ.get("FINOPS_EDGAR_CONTACT", "")
    fred_api_key: str = os.environ.get("FRED_API_KEY", "")

    @property
    def edgar_user_agent(self) -> str:
        # SEC asks for a descriptive User-Agent with a contact address.
        contact = f" {self.edgar_contact}" if self.edgar_contact else ""
        return f"finops-terminal/0.1 (personal research tool){contact}"


settings = Config()
