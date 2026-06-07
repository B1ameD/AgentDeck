class MaaMCPError(Exception):
    """Structured error for MAA MCP Server."""

    def __init__(self, code: str, message: str, detail: dict = None):
        self.code = code
        self.message = message
        self.detail = detail or {}
        super().__init__(f"[{code}] {message}")
