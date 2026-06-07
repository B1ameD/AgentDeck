import os
import tempfile
from pathlib import Path

import pytest

from maamcp.services.config import ConfigService
from maamcp.services.base import MaaMCPError


@pytest.fixture
def temp_config_dir():
    with tempfile.TemporaryDirectory() as tmpdir:
        yield Path(tmpdir)


@pytest.fixture
def config_service(temp_config_dir):
    return ConfigService(config_dir=temp_config_dir)


def test_read_config_not_found(config_service):
    with pytest.raises(MaaMCPError) as exc_info:
        config_service.read("nonexistent")
    assert exc_info.value.code == "CONFIG_NOT_FOUND"


def test_read_and_write_config(config_service, temp_config_dir):
    sample = {
        "core": {"client_type": "Official"},
        "tasks": [
            {"name": "刷关卡", "type": "Fight", "params": {"stage": "1-7", "medicine": 999}}
        ],
    }
    config_service.write("daily", sample)

    result = config_service.read("daily")
    assert result["core"]["client_type"] == "Official"
    assert result["tasks"][0]["params"]["stage"] == "1-7"


def test_merge_override(config_service, temp_config_dir):
    base = {
        "tasks": [
            {"name": "刷关卡", "type": "Fight", "params": {"stage": "1-7", "medicine": 999}}
        ],
    }
    config_service.write("daily", base)

    overrides = {"stage": "CE-6", "medicine": 10}
    merged = config_service.merge_override("daily", overrides)

    fight_task = merged["tasks"][0]
    assert fight_task["params"]["stage"] == "CE-6"
    assert fight_task["params"]["medicine"] == 10


def test_get_fight_config(config_service, temp_config_dir):
    sample = {
        "tasks": [
            {"name": "刷关卡", "type": "Fight", "params": {"stage": "1-7", "medicine": 999, "expiring_medicine": True, "stone": 0, "times": 0, "series": 0}}
        ],
    }
    config_service.write("daily", sample)

    result = config_service.get_fight_config("daily")
    assert result["stage"] == "1-7"
    assert result["medicine"] == 999
    assert result["expiring_medicine"] is True
