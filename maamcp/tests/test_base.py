import pytest
from maamcp.services.base import MaaMCPError


def test_maa_mcp_error_basic():
    err = MaaMCPError("TEST_ERROR", "test message")
    assert err.code == "TEST_ERROR"
    assert err.message == "test message"
    assert str(err) == "[TEST_ERROR] test message"


def test_maa_mcp_error_with_detail():
    err = MaaMCPError("TEST_ERROR", "test message", detail={"key": "value"})
    assert err.detail == {"key": "value"}


def test_maa_mcp_error_default_detail():
    err = MaaMCPError("TEST_ERROR", "test message")
    assert err.detail == {}
