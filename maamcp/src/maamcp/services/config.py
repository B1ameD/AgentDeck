import shutil
from pathlib import Path
from typing import Any

import tomli
import tomli_w

from maamcp.services.base import MaaMCPError
from maamcp.utils.logger import get_logger

logger = get_logger(__name__)

DEFAULT_CONFIG_DIR = Path.home() / "Library/Application Support/com.loong.maa/config/tasks"


class ConfigService:
    def __init__(self, config_dir: Path = None):
        self.config_dir = config_dir or DEFAULT_CONFIG_DIR

    def _config_path(self, task: str) -> Path:
        return self.config_dir / f"{task}.toml"

    def read(self, task: str) -> dict:
        """Read a task configuration from TOML file."""
        path = self._config_path(task)
        if not path.exists():
            raise MaaMCPError("CONFIG_NOT_FOUND", f"Configuration not found: {path}")

        with open(path, "rb") as f:
            return tomli.load(f)

    def write(self, task: str, config: dict) -> Path:
        """Write a task configuration to TOML file."""
        path = self._config_path(task)
        self.config_dir.mkdir(parents=True, exist_ok=True)

        if path.exists():
            backup = path.with_suffix(f".toml.bak")
            shutil.copy2(path, backup)

        with open(path, "wb") as f:
            tomli_w.dump(config, f)

        logger.info(f"Config written: {path}")
        return path

    def merge_override(self, task: str, overrides: dict) -> dict:
        """Read config and apply fight parameter overrides."""
        config = self.read(task)

        for t in config.get("tasks", []):
            if t.get("type") == "Fight":
                params = t.setdefault("params", {})
                for key, value in overrides.items():
                    if value is not None:
                        params[key] = value
                break

        return config

    def write_temp(self, task: str, config: dict) -> Path:
        """Write a temporary config file for one-time use."""
        import tempfile
        tmp_dir = Path(tempfile.gettempdir()) / "maamcp"
        tmp_dir.mkdir(exist_ok=True)
        path = tmp_dir / f"{task}_override.toml"

        with open(path, "wb") as f:
            tomli_w.dump(config, f)

        return path

    @staticmethod
    def cleanup_temp(path: Path):
        """Remove a temporary config file."""
        if path and path.exists():
            path.unlink()
            logger.info(f"Temp config cleaned up: {path}")

    def get_fight_config(self, task: str) -> dict:
        """Get fight-specific configuration."""
        config = self.read(task)

        for t in config.get("tasks", []):
            if t.get("type") == "Fight":
                params = t.get("params", {})
                return {
                    "task": task,
                    "stage": params.get("stage", ""),
                    "medicine": params.get("medicine", 0),
                    "expiring_medicine": params.get("expiring_medicine", False),
                    "stone": params.get("stone", 0),
                    "times": params.get("times", 0),
                    "series": params.get("series", 0),
                }

        raise MaaMCPError("CONFIG_NOT_FOUND", f"No Fight task found in {task}.toml")
