"""
Testes do /health do flag-service.

É o endpoint das liveness/readiness probes do Kubernetes: precisa responder
rápido, sem autenticação e sem depender do Postgres — se ele exigisse o banco,
uma indisponibilidade momentâneo do RDS derrubaria todos os pods em cascata.
"""


def test_health_retorna_200(client):
    resposta = client.get("/health")

    assert resposta.status_code == 200
    assert resposta.get_json() == {"status": "ok"}


def test_health_nao_exige_autenticacao(client):
    # Sem header Authorization de propósito.
    assert client.get("/health").status_code == 200


def test_health_nao_consulta_o_banco(client, db):
    client.get("/health")

    assert db.pool.getconn.call_count == 0


def test_health_nao_chama_o_auth_service(client, auth_ok):
    client.get("/health")

    assert auth_ok.chamadas == []


def test_health_responde_json(client):
    resposta = client.get("/health")

    assert resposta.content_type.startswith("application/json")
