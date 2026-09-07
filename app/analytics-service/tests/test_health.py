"""
Testes do /health do analytics-service.

O analytics-service é um consumidor: ele não recebe tráfego do Application
Gateway. O Flask existe só para dar às probes do Kubernetes um endpoint de
liveness — e ele precisa responder mesmo com a fila ou o Cosmos indisponíveis,
senão o Kubernetes reinicia o pod justamente quando ele está tentando reconectar.
"""


def test_health_retorna_200(client):
    resposta = client.get("/health")

    assert resposta.status_code == 200
    assert resposta.get_json() == {"status": "ok"}


def test_health_responde_json(client):
    assert client.get("/health").content_type.startswith("application/json")


def test_health_nao_depende_do_cosmos(client, cosmos):
    # Nenhuma leitura/escrita no Cosmos deve acontecer numa probe.
    client.get("/health")

    cosmos.create_item.assert_not_called()
    cosmos.query_items.assert_not_called()


def test_health_responde_mesmo_com_o_cosmos_quebrado(client, cosmos):
    cosmos.create_item.side_effect = RuntimeError("Cosmos fora do ar")

    assert client.get("/health").status_code == 200


def test_rota_inexistente_retorna_404(client):
    # O serviço não expõe API pública: qualquer outra rota é 404.
    assert client.get("/eventos").status_code == 404
