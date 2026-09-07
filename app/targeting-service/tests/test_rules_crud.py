"""
Testes do CRUD de regras de segmentação.

O ponto sensível aqui é a coluna `rules` (JSONB): ela precisa chegar ao Postgres
via psycopg2.extras.Json, não como string concatenada na query. É essa regra que
o evaluation-service lê para decidir o rollout percentual.
"""

import psycopg2
import pytest
from psycopg2.extras import Json

from conftest import AUTH_HEADERS

REGRA_PERCENTUAL = {"type": "PERCENTAGE", "value": 50}

REGRA_EXEMPLO = {
    "id": 1,
    "flag_name": "checkout-novo",
    "is_enabled": True,
    "rules": REGRA_PERCENTUAL,
}


def valor_json_adaptado(parametro):
    """Extrai o objeto original de dentro de um psycopg2.extras.Json."""
    assert isinstance(parametro, Json), f"esperava psycopg2.extras.Json, veio {type(parametro)}"
    return parametro.adapted


# --- POST /rules ---


class TestCriarRegra:
    def test_cria_e_retorna_201(self, client, db, auth_ok):
        db.cursor.fetchone.return_value = REGRA_EXEMPLO

        resposta = client.post(
            "/rules",
            headers=AUTH_HEADERS,
            json={"flag_name": "checkout-novo", "rules": REGRA_PERCENTUAL},
        )

        assert resposta.status_code == 201
        assert resposta.get_json()["flag_name"] == "checkout-novo"
        db.conexao.commit.assert_called_once()

    def test_serializa_o_jsonb_com_psycopg2_json(self, client, db, auth_ok):
        db.cursor.fetchone.return_value = REGRA_EXEMPLO

        client.post(
            "/rules",
            headers=AUTH_HEADERS,
            json={"flag_name": "checkout-novo", "rules": REGRA_PERCENTUAL},
        )

        _, parametros = db.cursor.execute.call_args[0]
        assert valor_json_adaptado(parametros[2]) == REGRA_PERCENTUAL

    def test_is_enabled_padrao_e_true(self, client, db, auth_ok):
        # Diferente do flag-service: uma regra criada já nasce valendo, porque o
        # kill switch global continua sendo o is_enabled da própria flag.
        db.cursor.fetchone.return_value = REGRA_EXEMPLO

        client.post(
            "/rules", headers=AUTH_HEADERS, json={"flag_name": "x", "rules": REGRA_PERCENTUAL}
        )

        _, parametros = db.cursor.execute.call_args[0]
        assert parametros[1] is True

    def test_usa_query_parametrizada_contra_sql_injection(self, client, db, auth_ok):
        db.cursor.fetchone.return_value = REGRA_EXEMPLO
        nome_malicioso = "flag'; DROP TABLE targeting_rules; --"

        client.post(
            "/rules",
            headers=AUTH_HEADERS,
            json={"flag_name": nome_malicioso, "rules": REGRA_PERCENTUAL},
        )

        sql, parametros = db.cursor.execute.call_args[0]
        assert nome_malicioso not in sql
        assert parametros[0] == nome_malicioso

    @pytest.mark.parametrize(
        "corpo",
        [
            {},
            {"flag_name": "x"},                      # sem rules
            {"rules": REGRA_PERCENTUAL},             # sem flag_name
        ],
    )
    def test_corpo_incompleto_retorna_400(self, client, db, auth_ok, corpo):
        resposta = client.post("/rules", headers=AUTH_HEADERS, json=corpo)

        assert resposta.status_code == 400
        assert db.cursor.execute.call_count == 0

    def test_regra_duplicada_retorna_409_e_faz_rollback(self, client, db, auth_ok):
        db.cursor.execute.side_effect = psycopg2.IntegrityError("duplicate key")

        resposta = client.post(
            "/rules",
            headers=AUTH_HEADERS,
            json={"flag_name": "checkout-novo", "rules": REGRA_PERCENTUAL},
        )

        assert resposta.status_code == 409
        db.conexao.rollback.assert_called_once()

    def test_erro_inesperado_retorna_500_e_devolve_a_conexao(self, client, db, auth_ok):
        db.cursor.execute.side_effect = RuntimeError("banco caiu")

        resposta = client.post(
            "/rules", headers=AUTH_HEADERS, json={"flag_name": "x", "rules": REGRA_PERCENTUAL}
        )

        assert resposta.status_code == 500
        db.conexao.rollback.assert_called_once()
        db.pool.putconn.assert_called_once_with(db.conexao)


# --- GET /rules/<flag_name> ---


class TestBuscarRegra:
    def test_regra_existente_retorna_200(self, client, db, auth_ok):
        db.cursor.fetchone.return_value = REGRA_EXEMPLO

        resposta = client.get("/rules/checkout-novo", headers=AUTH_HEADERS)

        assert resposta.status_code == 200
        assert resposta.get_json()["rules"] == REGRA_PERCENTUAL

    def test_regra_inexistente_retorna_404(self, client, db, auth_ok):
        # O evaluation-service trata este 404 como "sem segmentação" e libera a
        # flag para todos — por isso o status precisa ser exatamente 404.
        db.cursor.fetchone.return_value = None

        resposta = client.get("/rules/sem-regra", headers=AUTH_HEADERS)

        assert resposta.status_code == 404
        assert resposta.get_json()["error"] == "Regra não encontrada"

    def test_busca_pelo_flag_name_recebido(self, client, db, auth_ok):
        db.cursor.fetchone.return_value = REGRA_EXEMPLO

        client.get("/rules/checkout-novo", headers=AUTH_HEADERS)

        _, parametros = db.cursor.execute.call_args[0]
        assert parametros == ("checkout-novo",)


# --- PUT /rules/<flag_name> ---


class TestAtualizarRegra:
    def test_atualiza_o_jsonb(self, client, db, auth_ok):
        nova_regra = {"type": "PERCENTAGE", "value": 100}
        db.cursor.fetchone.return_value = {**REGRA_EXEMPLO, "rules": nova_regra}
        db.cursor.rowcount = 1

        resposta = client.put(
            "/rules/checkout-novo", headers=AUTH_HEADERS, json={"rules": nova_regra}
        )

        assert resposta.status_code == 200
        sql, parametros = db.cursor.execute.call_args[0]
        assert "rules = %s" in sql
        assert valor_json_adaptado(parametros[0]) == nova_regra
        assert parametros[-1] == "checkout-novo"

    def test_atualiza_somente_os_campos_enviados(self, client, db, auth_ok):
        db.cursor.fetchone.return_value = REGRA_EXEMPLO
        db.cursor.rowcount = 1

        client.put("/rules/checkout-novo", headers=AUTH_HEADERS, json={"is_enabled": False})

        sql, parametros = db.cursor.execute.call_args[0]
        assert "is_enabled = %s" in sql
        assert "rules = %s" not in sql
        assert parametros == (False, "checkout-novo")

    def test_desligar_a_regra_e_o_caminho_de_rollback_de_emergencia(self, client, db, auth_ok):
        # is_enabled=False na regra faz o evaluation-service liberar a flag para
        # 100% da base sem precisar reeditar o JSONB.
        db.cursor.fetchone.return_value = {**REGRA_EXEMPLO, "is_enabled": False}
        db.cursor.rowcount = 1

        resposta = client.put(
            "/rules/checkout-novo", headers=AUTH_HEADERS, json={"is_enabled": False}
        )

        assert resposta.status_code == 200
        assert resposta.get_json()["is_enabled"] is False
        db.conexao.commit.assert_called_once()

    def test_corpo_sem_campos_validos_retorna_400(self, client, db, auth_ok):
        resposta = client.put(
            "/rules/checkout-novo", headers=AUTH_HEADERS, json={"campo_inexistente": 1}
        )

        assert resposta.status_code == 400
        assert db.cursor.execute.call_count == 0

    def test_corpo_vazio_retorna_400(self, client, auth_ok):
        assert client.put("/rules/x", headers=AUTH_HEADERS, json={}).status_code == 400

    def test_regra_inexistente_retorna_404(self, client, db, auth_ok):
        db.cursor.rowcount = 0

        resposta = client.put("/rules/nao-existe", headers=AUTH_HEADERS, json={"is_enabled": True})

        assert resposta.status_code == 404
        db.conexao.commit.assert_not_called()

    def test_erro_no_banco_retorna_500_e_faz_rollback(self, client, db, auth_ok):
        db.cursor.execute.side_effect = RuntimeError("deadlock")

        resposta = client.put("/rules/x", headers=AUTH_HEADERS, json={"is_enabled": True})

        assert resposta.status_code == 500
        db.conexao.rollback.assert_called_once()


# --- DELETE /rules/<flag_name> ---


class TestDeletarRegra:
    def test_deleta_e_retorna_204(self, client, db, auth_ok):
        db.cursor.rowcount = 1

        resposta = client.delete("/rules/checkout-novo", headers=AUTH_HEADERS)

        assert resposta.status_code == 204
        assert resposta.data == b""
        db.conexao.commit.assert_called_once()

    def test_regra_inexistente_retorna_404(self, client, db, auth_ok):
        db.cursor.rowcount = 0

        resposta = client.delete("/rules/nao-existe", headers=AUTH_HEADERS)

        assert resposta.status_code == 404
        db.conexao.commit.assert_not_called()

    def test_erro_no_banco_retorna_500_e_faz_rollback(self, client, db, auth_ok):
        db.cursor.execute.side_effect = RuntimeError("permissão negada")

        resposta = client.delete("/rules/x", headers=AUTH_HEADERS)

        assert resposta.status_code == 500
        db.conexao.rollback.assert_called_once()


# --- Gestão do pool ---


@pytest.mark.parametrize(
    "metodo,rota,corpo",
    [
        ("post", "/rules", {"flag_name": "x", "rules": REGRA_PERCENTUAL}),
        ("get", "/rules/x", None),
        ("put", "/rules/x", {"is_enabled": True}),
        ("delete", "/rules/x", None),
    ],
)
def test_toda_rota_devolve_a_conexao_ao_pool(client, db, auth_ok, metodo, rota, corpo):
    db.cursor.fetchone.return_value = REGRA_EXEMPLO
    db.cursor.rowcount = 1

    getattr(client, metodo)(rota, headers=AUTH_HEADERS, json=corpo)

    assert db.pool.getconn.call_count == db.pool.putconn.call_count
