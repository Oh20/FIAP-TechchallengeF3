"""
Testes do middleware require_auth do targeting-service.

A implementação é idêntica à do flag-service, mas precisa de cobertura própria:
os dois arquivos evoluem separadamente e uma divergência silenciosa entre eles
já causaria comportamento inconsistente entre os serviços.
"""

import requests

from conftest import AUTH_HEADERS

ROTAS_PROTEGIDAS = [
    ("POST", "/rules"),
    ("GET", "/rules/minha-flag"),
    ("PUT", "/rules/minha-flag"),
    ("DELETE", "/rules/minha-flag"),
]


class TestSemHeader:
    def test_todas_as_rotas_protegidas_exigem_authorization(self, client):
        for metodo, rota in ROTAS_PROTEGIDAS:
            resposta = client.open(rota, method=metodo, json={"flag_name": "x", "rules": {}})
            assert resposta.status_code == 401, f"{metodo} {rota} não exigiu Authorization"

    def test_sem_header_nao_consulta_o_banco(self, client, db):
        client.get("/rules/x")
        assert db.pool.getconn.call_count == 0


class TestRespostaDoAuthService:
    def test_chave_invalida_retorna_401(self, client, auth_falha):
        auth_falha(status=401)

        resposta = client.get("/rules/x", headers=AUTH_HEADERS)

        assert resposta.status_code == 401
        assert resposta.get_json()["error"] == "Chave de API inválida"

    def test_qualquer_status_diferente_de_200_retorna_401(self, client, auth_falha):
        for status in (403, 404, 500, 502):
            auth_falha(status=status)
            resposta = client.get("/rules/x", headers=AUTH_HEADERS)
            assert resposta.status_code == 401, f"status {status} do auth-service liberou o acesso"

    def test_chave_invalida_nao_consulta_o_banco(self, client, db, auth_falha):
        auth_falha(status=401)

        client.get("/rules/x", headers=AUTH_HEADERS)

        assert db.pool.getconn.call_count == 0


class TestIndisponibilidadeDoAuthService:
    def test_timeout_retorna_504(self, client, auth_falha):
        auth_falha(excecao=requests.exceptions.Timeout("estourou o tempo"))

        resposta = client.get("/rules/x", headers=AUTH_HEADERS)

        assert resposta.status_code == 504

    def test_connection_error_retorna_503(self, client, auth_falha):
        auth_falha(excecao=requests.exceptions.ConnectionError("conexão recusada"))

        resposta = client.get("/rules/x", headers=AUTH_HEADERS)

        assert resposta.status_code == 503


class TestChamadaAoAuthService:
    def test_repassa_o_header_recebido(self, client, auth_ok):
        client.get("/rules/x", headers=AUTH_HEADERS)

        assert auth_ok.chamadas[0].kwargs["headers"]["Authorization"] == AUTH_HEADERS["Authorization"]

    def test_chama_o_endpoint_validate(self, client, auth_ok, modulo):
        client.get("/rules/x", headers=AUTH_HEADERS)

        assert auth_ok.chamadas[0].url == f"{modulo.AUTH_SERVICE_URL}/validate"

    def test_usa_timeout_para_nao_travar_o_pod(self, client, auth_ok):
        client.get("/rules/x", headers=AUTH_HEADERS)

        assert auth_ok.chamadas[0].kwargs.get("timeout") == 3
