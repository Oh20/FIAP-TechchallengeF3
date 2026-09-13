"""
Testes do CRUD de feature flags.

Todos usam o pool de conexões dublê (fixture `db`) e o auth-service dublê
(fixture `auth_ok`), então nenhum teste depende de Postgres nem de rede.
"""

import psycopg2
import pytest

from conftest import AUTH_HEADERS

FLAG_EXEMPLO = {
    "id": 1,
    "name": "checkout-novo",
    "description": "novo fluxo de checkout",
    "is_enabled": False,
}


# --- POST /flags ---


class TestCriarFlag:
    def test_cria_e_retorna_201(self, client, db, auth_ok):
        db.cursor.fetchone.return_value = FLAG_EXEMPLO

        resposta = client.post(
            "/flags",
            headers=AUTH_HEADERS,
            json={"name": "checkout-novo", "description": "novo fluxo de checkout"},
        )

        assert resposta.status_code == 201
        assert resposta.get_json()["name"] == "checkout-novo"
        db.conexao.commit.assert_called_once()

    def test_usa_query_parametrizada_contra_sql_injection(self, client, db, auth_ok):
        db.cursor.fetchone.return_value = FLAG_EXEMPLO
        nome_malicioso = "flag'; DROP TABLE flags; --"

        client.post("/flags", headers=AUTH_HEADERS, json={"name": nome_malicioso})

        sql, parametros = db.cursor.execute.call_args[0]
        assert nome_malicioso not in sql, "o valor foi interpolado direto no SQL"
        assert parametros[0] == nome_malicioso

    def test_is_enabled_padrao_e_false(self, client, db, auth_ok):
        # Uma flag nova nunca pode nascer ligada em produção.
        db.cursor.fetchone.return_value = FLAG_EXEMPLO

        client.post("/flags", headers=AUTH_HEADERS, json={"name": "nova-flag"})

        _, parametros = db.cursor.execute.call_args[0]
        assert parametros[2] is False

    def test_description_padrao_e_vazia(self, client, db, auth_ok):
        db.cursor.fetchone.return_value = FLAG_EXEMPLO

        client.post("/flags", headers=AUTH_HEADERS, json={"name": "nova-flag"})

        _, parametros = db.cursor.execute.call_args[0]
        assert parametros[1] == ""

    def test_sem_name_retorna_400(self, client, db, auth_ok):
        resposta = client.post("/flags", headers=AUTH_HEADERS, json={"description": "sem nome"})

        assert resposta.status_code == 400
        assert db.cursor.execute.call_count == 0

    def test_corpo_vazio_retorna_400(self, client, auth_ok):
        resposta = client.post("/flags", headers=AUTH_HEADERS, json={})

        assert resposta.status_code == 400

    def test_flag_duplicada_retorna_409_e_faz_rollback(self, client, db, auth_ok):
        db.cursor.execute.side_effect = psycopg2.IntegrityError("duplicate key")

        resposta = client.post("/flags", headers=AUTH_HEADERS, json={"name": "checkout-novo"})

        assert resposta.status_code == 409
        db.conexao.rollback.assert_called_once()
        db.conexao.commit.assert_not_called()

    def test_erro_inesperado_retorna_500_e_faz_rollback(self, client, db, auth_ok):
        db.cursor.execute.side_effect = RuntimeError("banco caiu")

        resposta = client.post("/flags", headers=AUTH_HEADERS, json={"name": "x"})

        assert resposta.status_code == 500
        db.conexao.rollback.assert_called_once()

    def test_devolve_a_conexao_ao_pool_mesmo_com_erro(self, client, db, auth_ok):
        # Vazar conexão do pool (máximo 5) esgota o serviço em poucos requests.
        db.cursor.execute.side_effect = RuntimeError("banco caiu")

        client.post("/flags", headers=AUTH_HEADERS, json={"name": "x"})

        db.pool.putconn.assert_called_once_with(db.conexao)
        db.cursor.close.assert_called_once()


# --- GET /flags ---


class TestListarFlags:
    def test_lista_flags(self, client, db, auth_ok):
        db.cursor.fetchall.return_value = [FLAG_EXEMPLO, {**FLAG_EXEMPLO, "id": 2, "name": "dark-mode"}]

        resposta = client.get("/flags", headers=AUTH_HEADERS)

        assert resposta.status_code == 200
        assert [f["name"] for f in resposta.get_json()] == ["checkout-novo", "dark-mode"]

    def test_lista_vazia_retorna_200(self, client, db, auth_ok):
        db.cursor.fetchall.return_value = []

        resposta = client.get("/flags", headers=AUTH_HEADERS)

        assert resposta.status_code == 200
        assert resposta.get_json() == []

    def test_ordena_por_nome(self, client, db, auth_ok):
        client.get("/flags", headers=AUTH_HEADERS)

        sql = db.cursor.execute.call_args[0][0]
        assert "ORDER BY name" in sql

    def test_erro_no_banco_retorna_500(self, client, db, auth_ok):
        db.cursor.execute.side_effect = RuntimeError("timeout")

        resposta = client.get("/flags", headers=AUTH_HEADERS)

        assert resposta.status_code == 500
        db.pool.putconn.assert_called_once()


# --- GET /flags/<name> ---


class TestBuscarFlag:
    def test_flag_existente_retorna_200(self, client, db, auth_ok):
        db.cursor.fetchone.return_value = FLAG_EXEMPLO

        resposta = client.get("/flags/checkout-novo", headers=AUTH_HEADERS)

        assert resposta.status_code == 200
        assert resposta.get_json()["name"] == "checkout-novo"

    def test_flag_inexistente_retorna_404(self, client, db, auth_ok):
        db.cursor.fetchone.return_value = None

        resposta = client.get("/flags/nao-existe", headers=AUTH_HEADERS)

        assert resposta.status_code == 404
        assert resposta.get_json()["error"] == "Flag não encontrada"

    def test_busca_pelo_nome_recebido(self, client, db, auth_ok):
        db.cursor.fetchone.return_value = FLAG_EXEMPLO

        client.get("/flags/checkout-novo", headers=AUTH_HEADERS)

        _, parametros = db.cursor.execute.call_args[0]
        assert parametros == ("checkout-novo",)


# --- PUT /flags/<name> ---


class TestAtualizarFlag:
    def test_atualiza_is_enabled(self, client, db, auth_ok):
        db.cursor.fetchone.return_value = {**FLAG_EXEMPLO, "is_enabled": True}
        db.cursor.rowcount = 1

        resposta = client.put(
            "/flags/checkout-novo", headers=AUTH_HEADERS, json={"is_enabled": True}
        )

        assert resposta.status_code == 200
        assert resposta.get_json()["is_enabled"] is True
        db.conexao.commit.assert_called_once()

    def test_atualiza_somente_os_campos_enviados(self, client, db, auth_ok):
        db.cursor.fetchone.return_value = FLAG_EXEMPLO
        db.cursor.rowcount = 1

        client.put("/flags/checkout-novo", headers=AUTH_HEADERS, json={"is_enabled": True})

        sql, parametros = db.cursor.execute.call_args[0]
        assert "is_enabled = %s" in sql
        assert "description = %s" not in sql
        assert parametros == (True, "checkout-novo")

    def test_atualiza_os_dois_campos(self, client, db, auth_ok):
        db.cursor.fetchone.return_value = FLAG_EXEMPLO
        db.cursor.rowcount = 1

        client.put(
            "/flags/checkout-novo",
            headers=AUTH_HEADERS,
            json={"description": "nova descrição", "is_enabled": False},
        )

        sql, parametros = db.cursor.execute.call_args[0]
        assert "description = %s" in sql and "is_enabled = %s" in sql
        assert parametros == ("nova descrição", False, "checkout-novo")

    def test_corpo_sem_campos_validos_retorna_400(self, client, db, auth_ok):
        resposta = client.put(
            "/flags/checkout-novo", headers=AUTH_HEADERS, json={"campo_inexistente": 1}
        )

        assert resposta.status_code == 400
        assert db.cursor.execute.call_count == 0

    def test_corpo_vazio_retorna_400(self, client, auth_ok):
        resposta = client.put("/flags/checkout-novo", headers=AUTH_HEADERS, json={})

        assert resposta.status_code == 400

    def test_flag_inexistente_retorna_404(self, client, db, auth_ok):
        db.cursor.rowcount = 0

        resposta = client.put(
            "/flags/nao-existe", headers=AUTH_HEADERS, json={"is_enabled": True}
        )

        assert resposta.status_code == 404
        db.conexao.commit.assert_not_called()

    def test_erro_no_banco_retorna_500_e_faz_rollback(self, client, db, auth_ok):
        db.cursor.execute.side_effect = RuntimeError("deadlock")

        resposta = client.put(
            "/flags/checkout-novo", headers=AUTH_HEADERS, json={"is_enabled": True}
        )

        assert resposta.status_code == 500
        db.conexao.rollback.assert_called_once()


# --- DELETE /flags/<name> ---


class TestDeletarFlag:
    def test_deleta_e_retorna_204(self, client, db, auth_ok):
        db.cursor.rowcount = 1

        resposta = client.delete("/flags/checkout-novo", headers=AUTH_HEADERS)

        assert resposta.status_code == 204
        assert resposta.data == b""
        db.conexao.commit.assert_called_once()

    def test_flag_inexistente_retorna_404(self, client, db, auth_ok):
        db.cursor.rowcount = 0

        resposta = client.delete("/flags/nao-existe", headers=AUTH_HEADERS)

        assert resposta.status_code == 404
        db.conexao.commit.assert_not_called()

    def test_erro_no_banco_retorna_500_e_faz_rollback(self, client, db, auth_ok):
        db.cursor.execute.side_effect = RuntimeError("permissão negada")

        resposta = client.delete("/flags/checkout-novo", headers=AUTH_HEADERS)

        assert resposta.status_code == 500
        db.conexao.rollback.assert_called_once()


# --- Gestão do pool ---


@pytest.mark.parametrize(
    "metodo,rota,corpo",
    [
        ("post", "/flags", {"name": "x"}),
        ("get", "/flags", None),
        ("get", "/flags/x", None),
        ("put", "/flags/x", {"is_enabled": True}),
        ("delete", "/flags/x", None),
    ],
)
def test_toda_rota_devolve_a_conexao_ao_pool(client, db, auth_ok, metodo, rota, corpo):
    db.cursor.fetchone.return_value = FLAG_EXEMPLO
    db.cursor.rowcount = 1

    getattr(client, metodo)(rota, headers=AUTH_HEADERS, json=corpo)

    assert db.pool.getconn.call_count == db.pool.putconn.call_count
