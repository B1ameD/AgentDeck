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
    cwd: str = None,
    env: dict = None,
) -> CommandResult:
    """Run a shell command asynchronously with timeout."""
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
    except TimeoutError:
        proc.kill()
        await proc.wait()
        raise MaaMCPError(
            "COMMAND_TIMEOUT",
            f"Command timed out after {timeout}s: {' '.join(cmd)}",
        )
    except Exception as e:
        raise MaaMCPError(
            "COMMAND_EXEC_ERROR",
            f"Failed to execute command: {' '.join(cmd)}: {e}",
        )

    stdout = stdout_bytes.decode("utf-8", errors="replace").strip()
    stderr = stderr_bytes.decode("utf-8", errors="replace").strip()

    if proc.returncode != 0:
        raise MaaMCPError(
            "COMMAND_FAILED",
            f"Command failed with code {proc.returncode}: {' '.join(cmd)}",
            detail={"stdout": stdout, "stderr": stderr, "returncode": proc.returncode},
        )

    return CommandResult(stdout=stdout, stderr=stderr, returncode=proc.returncode)
