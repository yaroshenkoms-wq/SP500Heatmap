import pytest


@pytest.fixture(autouse=True)
def _no_benchmarks_by_default(request, monkeypatch):
    """Ряды индексов (^GSPC…) добавляются к курсам валют; старые тесты сверяют точные списки символов,
    поэтому в них ряды выключены. Тест с маркой `benchmarks` проверяет их явно."""
    if request.node.get_closest_marker("benchmarks"):
        return
    try:
        import fetch_world
        monkeypatch.setattr(fetch_world, "BENCHMARK_SYMBOLS", [])
    except ImportError:
        pass


def pytest_configure(config):
    config.addinivalue_line("markers", "benchmarks: тест проверяет ряды индексов")
