"""
Configuração compartilhada dos testes unitários do analytics-service.

O app.py é o mais agressivo dos cinco no momento do import: valida variáveis
obrigatórias (com sys.exit(1)), instancia um CosmosClient real e ainda chama
start_worker(), que sobe uma thread ligando no Azure Service Bus em loop
infinito.

Este conftest neutraliza os três antes do import — o Cosmos vira dublê e a
thread do worker vira um objeto inerte cujos argumentos ficam registrados para
inspeção nos testes.
"""

import os
import sys
import threading
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest

SERVICE_DIR = Path(__file__).resolve().parents[1]
if str(SERVICE_DIR) not in sys.path:
    sys.path.insert(0, str(SERVICE_DIR))

# Sem estas três o app.py chama sys.exit(1) já no import.
os.environ.setdefault(
    "SERVICE_BUS_CONNECTION_STRING",
    "Endpoint=sb://teste.servicebus.windows.net/;SharedAccessKeyName=teste;SharedAccessKey=fake",
)
os.environ.setdefault("SERVICE_BUS_QUEUE_NAME", "togglemaster-events-test")
os.environ.setdefault("COSMOS_ENDPOINT", "https://teste.documents.azure.com:443/")
os.environ.setdefault("COSMOS_KEY", "chave-fake-de-teste")

import azure.cosmos  # noqa: E402

# Registra como a thread do worker foi criada, sem de fato iniciá-la.
THREADS_CRIADAS = []


class _ThreadInerte:
    def __init__(self, *args, **kwargs):
        self.args = args
        self.kwargs = kwargs
        self.iniciada = False
        THREADS_CRIADAS.append(self)

    def start(self):
        self.iniciada = True


_cosmos_real = azure.cosmos.CosmosClient
_thread_real = threading.Thread

azure.cosmos.CosmosClient = MagicMock(name="CosmosClient")
threading.Thread = _ThreadInerte
try:
    import app as analytics_app  # noqa: E402
finally:
    azure.cosmos.CosmosClient = _cosmos_real
    threading.Thread = _thread_real


@pytest.fixture
def modulo():
    """Dá acesso direto ao módulo app.py importado."""
    return analytics_app


@pytest.fixture
def cosmos(monkeypatch):
    """Substitui o container do Cosmos DB por um dublê limpo a cada teste."""
    container = MagicMock(name="container")
    monkeypatch.setattr(analytics_app, "container", container)
    return container


@pytest.fixture
def client():
    """Cliente de teste do Flask (só existe o /health, para as probes)."""
    analytics_app.app.config["TESTING"] = True
    with analytics_app.app.test_client() as c:
        yield c


class MensagemFake:
    """
    Dublê de mensagem do Service Bus.

    O app.py lê o corpo com json.loads(str(message)) — o SDK do Azure define
    __str__ para devolver o payload —, então basta reproduzir esse contrato.
    """

    def __init__(self, corpo):
        self._corpo = corpo

    def __str__(self):
        return self._corpo


def evento_valido(**sobrescritas):
    """Payload igual ao publicado pelo evaluation-service (servicebus.go)."""
    evento = {
        "user_id": "user-1",
        "flag_name": "checkout-novo",
        "result": True,
        "timestamp": "2026-01-15T10:30:00Z",
    }
    evento.update(sobrescritas)
    return evento


@pytest.fixture
def mensagem():
    """Fábrica de mensagens: recebe um dict (ou string crua) e devolve o dublê."""
    import json

    def criar(payload=None, **sobrescritas):
        if payload is None:
            payload = evento_valido(**sobrescritas)
        if isinstance(payload, str):
            return MensagemFake(payload)
        return MensagemFake(json.dumps(payload))

    return SimpleNamespace(criar=criar, evento_valido=evento_valido)
