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
    with patch("maamcp.utils.executor.asyncio.create_subprocess_exec") as mock_exec, \
         patch("maamcp.utils.executor.asyncio.wait_for") as mock_wait:
        mock_proc = MagicMock()
        mock_proc.kill = MagicMock()
        mock_proc.wait = AsyncMock()
        mock_exec.return_value = mock_proc

        async def wait_for_side_effect(coro, timeout):
            if isinstance(coro, type(mock_proc.communicate())) and hasattr(coro, '__name__') is False:
                # first call: proc.communicate()
                raise asyncio.TimeoutError()
            # second call: proc.wait()
            return await coro

        mock_wait.side_effect = wait_for_side_effect

        with pytest.raises(MaaMCPError) as exc_info:
            await run_command(["sleep", "10"], timeout=1)
        assert exc_info.value.code == "COMMAND_TIMEOUT"
        mock_proc.kill.assert_called_once()
        mock_proc.wait.assert_awaited_once()


@pytest.mark.asyncio
async def test_run_command_exec_failure():
    with patch("maamcp.utils.executor.asyncio.create_subprocess_exec") as mock_exec:
        mock_exec.side_effect = FileNotFoundError("no such file")

        with pytest.raises(MaaMCPError) as exc_info:
            await run_command(["nonexistent_binary"])
        assert exc_info.value.code == "COMMAND_EXEC_ERROR"
        assert "nonexistent_binary" in exc_info.value.message


@pytest.mark.asyncio
async def test_run_command_timeout_kills_process():
    with patch("maamcp.utils.executor.asyncio.create_subprocess_exec") as mock_exec, \
         patch("maamcp.utils.executor.asyncio.wait_for") as mock_wait:
        mock_proc = MagicMock()
        mock_proc.kill = MagicMock()
        mock_proc.wait = AsyncMock(return_value=0)
        mock_exec.return_value = mock_proc

        call_count = 0
        async def wait_for_side_effect(coro, timeout):
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                raise asyncio.TimeoutError()
            return await coro

        mock_wait.side_effect = wait_for_side_effect

        with pytest.raises(MaaMCPError) as exc_info:
            await run_command(["sleep", "10"], timeout=1)
        assert exc_info.value.code == "COMMAND_TIMEOUT"
        mock_proc.kill.assert_called_once()
        mock_proc.wait.assert_awaited_once()
