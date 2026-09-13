"""
Testes do consumo de eventos do Service Bus e da gravação no Cosmos DB.

O contrato de confiabilidade do serviço é at-least-once: process_message só
pode devolver True depois de gravar com sucesso. Devolver True por engano em um
caminho de falha significa confirmar (complete) a mensagem e perder o evento.
"""

import json

import pytest
from azure.cosmos import exceptions as cosmos_exceptions

from conftest import evento_valido


class TestGravacaoComSucesso:
    def test_evento_valido_retorna_true(self, modulo, cosmos, mensagem):
        assert modulo.process_message(mensagem.criar()) is True

    def test_grava_uma_vez_no_cosmos(self, modulo, cosmos, mensagem):
        modulo.process_message(mensagem.criar())

        cosmos.create_item.assert_called_once()

    def test_mapeia_todos_os_campos_do_evento(self, modulo, cosmos, mensagem):
        modulo.process_message(mensagem.criar())

        item = cosmos.create_item.call_args.kwargs["body"]
        assert item["user_id"] == "user-1"
        assert item["flag_name"] == "checkout-novo"
        assert item["result"] is True
        assert item["timestamp"] == "2026-01-15T10:30:00Z"

    def test_id_obrigatorio_do_cosmos_e_igual_ao_event_id(self, modulo, cosmos, mensagem):
        modulo.process_message(mensagem.criar())

        item = cosmos.create_item.call_args.kwargs["body"]
        assert item["id"] == item["event_id"]
        assert item["id"], "o Cosmos DB exige o campo 'id' preenchido"

    def test_cada_evento_recebe_um_id_unico(self, modulo, cosmos, mensagem):
        # Sem id único, o reprocessamento (at-least-once) colidiria na chave.
        for _ in range(20):
            modulo.process_message(mensagem.criar())

        ids = {chamada.kwargs["body"]["id"] for chamada in cosmos.create_item.call_args_list}
        assert len(ids) == 20

    def test_flag_name_e_a_partition_key(self, modulo, cosmos, mensagem):
        # O container é particionado por flag_name: sem esse campo o Cosmos
        # rejeita o documento.
        modulo.process_message(mensagem.criar(flag_name="dark-mode"))

        assert cosmos.create_item.call_args.kwargs["body"]["flag_name"] == "dark-mode"

    def test_result_false_tambem_e_gravado(self, modulo, cosmos, mensagem):
        # Avaliação negativa é dado de analytics tão válido quanto a positiva.
        assert modulo.process_message(mensagem.criar(result=False)) is True

        assert cosmos.create_item.call_args.kwargs["body"]["result"] is False


class TestPoisonPill:
    def test_json_invalido_e_descartado_com_true(self, modulo, cosmos, mensagem):
        # True = confirma na fila. É proposital: uma mensagem malformada nunca
        # vai ser processada e ficaria travando a fila para sempre.
        assert modulo.process_message(mensagem.criar("isso não é json")) is True

        cosmos.create_item.assert_not_called()

    def test_json_vazio_e_descartado(self, modulo, cosmos, mensagem):
        assert modulo.process_message(mensagem.criar("")) is True

        cosmos.create_item.assert_not_called()

    @pytest.mark.parametrize("campo", ["user_id", "flag_name", "result", "timestamp"])
    def test_campo_obrigatorio_ausente_devolve_para_a_fila(self, modulo, cosmos, mensagem, campo):
        # KeyError cai no except genérico -> False -> abandon_message.
        incompleto = evento_valido()
        del incompleto[campo]

        assert modulo.process_message(mensagem.criar(incompleto)) is False

        cosmos.create_item.assert_not_called()


class TestFalhaNoCosmos:
    def test_erro_http_do_cosmos_devolve_para_a_fila(self, modulo, cosmos, mensagem):
        cosmos.create_item.side_effect = cosmos_exceptions.CosmosHttpResponseError(
            status_code=503, message="Service Unavailable"
        )

        assert modulo.process_message(mensagem.criar()) is False

    def test_erro_inesperado_devolve_para_a_fila(self, modulo, cosmos, mensagem):
        cosmos.create_item.side_effect = RuntimeError("conexão perdida")

        assert modulo.process_message(mensagem.criar()) is False

    def test_nao_confirma_a_mensagem_quando_a_gravacao_falha(self, modulo, cosmos, mensagem):
        # Este é o teste que protege contra perda de dados: se ele passar a
        # devolver True, o evento é apagado da fila sem ter sido persistido.
        cosmos.create_item.side_effect = cosmos_exceptions.CosmosHttpResponseError(
            status_code=500, message="Internal Server Error"
        )

        resultado = modulo.process_message(mensagem.criar())

        assert resultado is not True


class TestContratoComOEvaluationService:
    def test_le_o_payload_publicado_pelo_evaluation_service(self, modulo, cosmos, mensagem):
        # Payload copiado da struct EvaluationEvent de servicebus.go.
        payload = json.dumps(
            {
                "user_id": "user-42",
                "flag_name": "dark-mode",
                "result": False,
                "timestamp": "2026-01-15T10:30:00Z",
            }
        )

        assert modulo.process_message(mensagem.criar(payload)) is True

        item = cosmos.create_item.call_args.kwargs["body"]
        assert item["user_id"] == "user-42"
        assert item["flag_name"] == "dark-mode"
        assert item["result"] is False


class TestWorker:
    def test_o_worker_sobe_como_daemon(self, modulo):
        # daemon=True evita que a thread do worker segure o shutdown do pod.
        from conftest import THREADS_CRIADAS

        assert THREADS_CRIADAS, "start_worker() deveria ter criado a thread do worker"
        worker = THREADS_CRIADAS[-1]
        assert worker.kwargs.get("daemon") is True
        assert worker.kwargs.get("target") is modulo.service_bus_worker_loop
        assert worker.iniciada is True

    def test_o_worker_reconecta_apos_falha_no_service_bus(self, modulo, monkeypatch):
        class PararLoop(Exception):
            """Sentinela para sair do `while True` do worker."""

        def falha_ao_conectar(*args, **kwargs):
            raise RuntimeError("service bus fora do ar")

        esperas = []

        def fake_sleep(segundos):
            esperas.append(segundos)
            raise PararLoop()

        monkeypatch.setattr(
            modulo.ServiceBusClient, "from_connection_string", falha_ao_conectar
        )
        monkeypatch.setattr(modulo.time, "sleep", fake_sleep)

        with pytest.raises(PararLoop):
            modulo.service_bus_worker_loop()

        # Falhou, esperou e voltaria a tentar — em vez de morrer silenciosamente.
        assert esperas == [10]
