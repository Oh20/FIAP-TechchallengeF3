"""
Configuração compartilhada dos testes unitários do targeting-service.

Assim como no flag-service, o app.py abre um SimpleConnectionPool real e chama
sys.exit(1) quando faltam variáveis de ambiente já no import. Este conftest
prepara o ambiente e troca o pool por um dublê ANTES de importar o módulo.
"""

import os
import sys
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest

SERVICE_DIR = Path(__file__).resolve().parents[1]
if str(SERVICE_DIR) not in sys.path:
    sys.path.insert(0, str(SERVICE_DIR))

os.environ.setdefault("DATABASE_URL", "postgresql://teste:teste@localhost:5432/targeting_test")
os.environ.setdefault("AUTH_SERVICE_URL", "http://auth-service.test:8001")

import psycopg2.pool  # noqa: E402

_pool_real = psycopg2.pool.SimpleConnectionPool
psycopg2.pool.SimpleConnectionPool = lambda *args, **kwargs: MagicMock(name="pool-de-import")
try:
    import app as targeting_app  # noqa: E402
finally:
    psycopg2.pool.SimpleConnectionPool = _pool_real


AUTH_HEADERS = {"Authorization": "Bearer tm_key_de_teste"}


@pytest.fixture
def modulo():
    """Dá acesso direto ao módulo app.py importado."""
    return targeting_app


@pytest.fixture
def db(monkeypatch):
    """Substitui o pool de conexões por dublês encadeados (pool -> conexão -> cursor)."""
    cursor = MagicMock(name="cursor")
    cursor.rowcount = 1
    cursor.fetchone.return_value = None
    cursor.fetchall.return_value = []

    conexao = MagicMock(name="conexao")
    conexao.cursor.return_value = cursor

    pool = MagicMock(name="pool")
    pool.getconn.return_value = conexao

    monkeypatch.setattr(targeting_app, "pool", pool)
    return SimpleNamespace(pool=pool, conexao=conexao, cursor=cursor)


@pytest.fixture
def client(db):
    targeting_app.app.config["TESTING"] = True
    with targeting_app.app.test_client() as c:
        yield c


@pytest.fixture
def auth_ok(monkeypatch):
    """Faz o auth-service responder 200 (chave válida) e registra as chamadas."""
    resposta = MagicMock(name="resposta-auth")
    resposta.status_code = 200

    chamadas = []

    def fake_get(url, **kwargs):
        chamadas.append(SimpleNamespace(url=url, kwargs=kwargs))
        return resposta

    monkeypatch.setattr(targeting_app.requests, "get", fake_get)
    return SimpleNamespace(chamadas=chamadas, resposta=resposta)


@pytest.fixture
def auth_falha(monkeypatch):
    """Configura a falha do auth-service: status != 200 ou exceção do requests."""

    def configurar(status=None, excecao=None):
        def fake_get(url, **kwargs):
            if excecao is not None:
                raise excecao
            resposta = MagicMock(name="resposta-auth")
            resposta.status_code = status
            return resposta

        monkeypatch.setattr(targeting_app.requests, "get", fake_get)

    return configurar
