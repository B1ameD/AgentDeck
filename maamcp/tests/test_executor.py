import pytest
import asyncio
from unittest.mock import patch, MagicMock, AsyncMock

from maamcp.utils.executor import run_command
from maamcp.services.base import MaaMCPError


@pytest.mark.asyncio
async def test_run_command_success():
    with patch("maamcp.utils.executor.asyncio.create_subprocess_exec") as mock_exec:
        mock_proc = MagicMock()
        mock_proc.returncode = 0
        mock_proc.communicate = AsyncMock(return_value=(b"stdout content", b"stderr content"))
        mock_exec.return_value = mock_proc

        result = await run_command(["echo", "hello"])
        assert result.stdout == "stdout content"
        assert result.stderr == "stderr content"
        assert result.returncode == 0


@pytest.mark.asyncio
async def test_run_command_failure():
    with patch("maamcp.utils.executor.asyncio.create_subprocess_exec") as mock_exec:
        mock_proc = MagicMock()
        mock_proc.returncode = 1
        mock_proc.communicate = AsyncMock(return_value=(b"", b"error msg"))
        mock_exec.return_value = mock_proc

        with pytest.raises(MaaMCPError) as exc_info:
            await run_command(["false"])
        assert exc_info.value.code == "COMMAND_FAILED"


@pytest.mark.asyncio
async def test_run_command_timeout():
    with patch("maamcp.utils.executor.asyncio.wait_for") as mock_wait:
        mock_wait.side_effect = asyncio.TimeoutError()

        with pytest.raises(MaaMCPError) as exc_info:
            await run_command(["sleep", "10"], timeout=1)
        assert exc_info.value.code == "COMMAND_TIMEOUT"
