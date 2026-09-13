"""
Configuração compartilhada dos testes unitários do flag-service.

O app.py faz três coisas no momento do import que impedem um teste unitário
ingênuo: lê variáveis de ambiente obrigatórias, chama sys.exit(1) se elas
faltarem e abre um SimpleConnectionPool de verdade contra o Postgres.

Por isso este conftest prepara o ambiente e troca o pool por um dublê ANTES de
importar o módulo — nenhum teste sobe banco, rede ou container.
"""

import os
import sys
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest

# O app.py fica na raiz do serviço, um nível acima de tests/.
SERVICE_DIR = Path(__file__).resolve().parents[1]
if str(SERVICE_DIR) not in sys.path:
    sys.path.insert(0, str(SERVICE_DIR))

# Variáveis obrigatórias: sem elas o app.py chama sys.exit(1) no import.
os.environ.setdefault("DATABASE_URL", "postgresql://teste:teste@localhost:5432/flags_test")
os.environ.setdefault("AUTH_SERVICE_URL", "http://auth-service.test:8001")

import psycopg2.pool  # noqa: E402

# Neutraliza a conexão real feita no import do app.py.
_pool_real = psycopg2.pool.SimpleConnectionPool
psycopg2.pool.SimpleConnectionPool = lambda *args, **kwargs: MagicMock(name="pool-de-import")
try:
    import app as flag_app  # noqa: E402
finally:
    psycopg2.pool.SimpleConnectionPool = _pool_real


# Header usado nas rotas protegidas. O valor não importa: quem decide se a
# chave é válida é o auth-service, que também é dublê nos testes.
AUTH_HEADERS = {"Authorization": "Bearer tm_key_de_teste"}


@pytest.fixture
def modulo():
    """Dá acesso direto ao módulo app.py importado."""
    return flag_app


@pytest.fixture
def db(monkeypatch):
    """
    Substitui o pool de conexões por dublês encadeados
    (pool -> conexão -> cursor) e devolve os três para inspeção.
    """
    cursor = MagicMock(name="cursor")
    cursor.rowcount = 1
    cursor.fetchone.return_value = None
    cursor.fetchall.return_value = []

    conexao = MagicMock(name="conexao")
    conexao.cursor.return_value = cursor

    pool = MagicMock(name="pool")
    pool.getconn.return_value = conexao

    monkeypatch.setattr(flag_app, "pool", pool)
    return SimpleNamespace(pool=pool, conexao=conexao, cursor=cursor)


@pytest.fixture
def client(db):
    """Cliente de teste do Flask, já com o banco dublê ativo."""
    flag_app.app.config["TESTING"] = True
    with flag_app.app.test_client() as c:
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

    monkeypatch.setattr(flag_app.requests, "get", fake_get)
    return SimpleNamespace(chamadas=chamadas, resposta=resposta)


@pytest.fixture
def auth_falha(monkeypatch):
    """
    Devolve uma função que configura a falha do auth-service:
    ou um status HTTP diferente de 200, ou uma exceção do requests.
    """

    def configurar(status=None, excecao=None):
        def fake_get(url, **kwargs):
            if excecao is not None:
                raise excecao
            resposta = MagicMock(name="resposta-auth")
            resposta.status_code = status
            return resposta

        monkeypatch.setattr(flag_app.requests, "get", fake_get)

    return configurar
