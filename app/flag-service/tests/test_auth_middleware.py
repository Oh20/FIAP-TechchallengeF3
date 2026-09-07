"""
Testes do middleware require_auth do flag-service.

O flag-service não valida chaves sozinho: ele delega ao auth-service. O que
importa aqui é o comportamento quando essa delegação dá errado — foi de onde
saiu o "vazamento de contexto de autenticação" citado na documentação da fase 2.
"""

import requests

from conftest import AUTH_HEADERS

# Rotas protegidas por require_auth (todas menos /health).
ROTAS_PROTEGIDAS = [
    ("GET", "/flags"),
    ("POST", "/flags"),
    ("GET", "/flags/minha-flag"),
    ("PUT", "/flags/minha-flag"),
    ("DELETE", "/flags/minha-flag"),
]


def chamar(client, metodo, rota, **kwargs):
    return client.open(rota, method=metodo, **kwargs)


class TestSemHeader:
    def test_todas_as_rotas_protegidas_exigem_authorization(self, client):
        for metodo, rota in ROTAS_PROTEGIDAS:
            resposta = chamar(client, metodo, rota, json={"name": "x"})
            assert resposta.status_code == 401, f"{metodo} {rota} não exigiu Authorization"
            assert "error" in resposta.get_json()

    def test_sem_header_nao_consulta_o_banco(self, client, db):
        chamar(client, "GET", "/flags")
        assert db.pool.getconn.call_count == 0


class TestRespostaDoAuthService:
    def test_chave_invalida_retorna_401(self, client, auth_falha):
        auth_falha(status=401)

        resposta = client.get("/flags", headers=AUTH_HEADERS)

        assert resposta.status_code == 401
        assert resposta.get_json()["error"] == "Chave de API inválida"

    def test_qualquer_status_diferente_de_200_retorna_401(self, client, auth_falha):
        # Fail-closed: um 500 do auth-service não pode virar acesso liberado.
        for status in (403, 404, 500, 502):
            auth_falha(status=status)
            resposta = client.get("/flags", headers=AUTH_HEADERS)
            assert resposta.status_code == 401, f"status {status} do auth-service liberou o acesso"

    def test_chave_invalida_nao_consulta_o_banco(self, client, db, auth_falha):
        auth_falha(status=401)

        client.get("/flags", headers=AUTH_HEADERS)

        assert db.pool.getconn.call_count == 0


class TestIndisponibilidadeDoAuthService:
    def test_timeout_retorna_504(self, client, auth_falha):
        auth_falha(excecao=requests.exceptions.Timeout("estourou o tempo"))

        resposta = client.get("/flags", headers=AUTH_HEADERS)

        assert resposta.status_code == 504
        assert "timeout" in resposta.get_json()["error"].lower()

    def test_connection_error_retorna_503(self, client, auth_falha):
        auth_falha(excecao=requests.exceptions.ConnectionError("conexão recusada"))

        resposta = client.get("/flags", headers=AUTH_HEADERS)

        assert resposta.status_code == 503

    def test_erro_generico_de_request_retorna_503(self, client, auth_falha):
        auth_falha(excecao=requests.exceptions.RequestException("falha genérica"))

        resposta = client.get("/flags", headers=AUTH_HEADERS)

        assert resposta.status_code == 503


class TestChamadaAoAuthService:
    def test_repassa_o_header_recebido(self, client, auth_ok):
        client.get("/flags", headers=AUTH_HEADERS)

        assert len(auth_ok.chamadas) == 1
        enviado = auth_ok.chamadas[0].kwargs["headers"]["Authorization"]
        assert enviado == AUTH_HEADERS["Authorization"]

    def test_chama_o_endpoint_validate(self, client, auth_ok, modulo):
        client.get("/flags", headers=AUTH_HEADERS)

        assert auth_ok.chamadas[0].url == f"{modulo.AUTH_SERVICE_URL}/validate"

    def test_usa_timeout_para_nao_travar_o_pod(self, client, auth_ok):
        # Sem timeout, uma falha do auth-service prenderia todos os workers do
        # gunicorn e derrubaria as probes do Kubernetes.
        client.get("/flags", headers=AUTH_HEADERS)

        assert auth_ok.chamadas[0].kwargs.get("timeout") == 3

    def test_valida_uma_vez_por_requisicao(self, client, auth_ok):
        client.get("/flags", headers=AUTH_HEADERS)

        assert len(auth_ok.chamadas) == 1
