"""
Testes do /health do targeting-service (probes do Kubernetes).
"""


def test_health_retorna_200(client):
    resposta = client.get("/health")

    assert resposta.status_code == 200
    assert resposta.get_json() == {"status": "ok"}


def test_health_nao_exige_autenticacao(client):
    assert client.get("/health").status_code == 200


def test_health_nao_consulta_o_banco(client, db):
    client.get("/health")

    assert db.pool.getconn.call_count == 0


def test_health_nao_chama_o_auth_service(client, auth_ok):
    client.get("/health")

    assert auth_ok.chamadas == []
