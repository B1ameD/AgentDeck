import asyncio
from dataclasses import dataclass

from maamcp.services.base import MaaMCPError


@dataclass
class CommandResult:
    stdout: str
    stderr: str
    returncode: int


async def run_command(
    cmd: list[str],
    *,
    timeout: float = 30.0,
    cwd: str | None = None,
    env: dict | None = None,
) -> CommandResult:
    """Run a shell command asynchronously with timeout."""
    cmd_str = " ".join(cmd)
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=cwd,
            env=env,
        )
        stdout_bytes, stderr_bytes = await asyncio.wait_for(
            proc.communicate(), timeout=timeout
        )
    except asyncio.TimeoutError:
        proc.kill()
        await asyncio.wait_for(proc.wait(), timeout=5.0)
        raise MaaMCPError(
            "COMMAND_TIMEOUT",
            f"Command timed out after {timeout}s: {cmd_str}",
        )
    except Exception as e:
        raise MaaMCPError(
            "COMMAND_EXEC_ERROR",
            f"Failed to execute command: {cmd_str}: {e}",
        )

    stdout = stdout_bytes.decode("utf-8", errors="replace").strip()
    stderr = stderr_bytes.decode("utf-8", errors="replace").strip()

    if proc.returncode != 0:
        raise MaaMCPError(
            "COMMAND_FAILED",
            f"Command failed with code {proc.returncode}: {cmd_str}",
            detail={"stdout": stdout, "stderr": stderr, "returncode": proc.returncode},
        )

    return CommandResult(stdout=stdout, stderr=stderr, returncode=proc.returncode)
