package main

import (
	"encoding/json"
	"testing"
	"time"
)

// Service Bus é opcional (ver main.go): sem ele o evento só é logado.
// Este teste garante que a ausência do cliente não derruba o serviço — a
// função roda como goroutine, então um pânico aqui mataria o processo inteiro.
func TestSendEvaluationEvent_SemClienteNaoEntraEmPanico(t *testing.T) {
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("sendEvaluationEvent entrou em pânico sem Service Bus: %v", r)
		}
	}()

	app := &App{ServiceBusClient: nil, ServiceBusQueueName: ""}
	app.sendEvaluationEvent("user-1", "checkout-novo", true)
}

func TestSendEvaluationEvent_SemNomeDeFilaNaoEntraEmPanico(t *testing.T) {
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("sendEvaluationEvent entrou em pânico com fila vazia: %v", r)
		}
	}()

	// Cliente nulo + fila vazia: o guard precisa cobrir os dois casos.
	app := &App{ServiceBusQueueName: ""}
	app.sendEvaluationEvent("user-1", "checkout-novo", false)
}

// Contrato de mensageria: o analytics-service lê exatamente estas chaves ao
// gravar no Cosmos DB (user_id, flag_name, result, timestamp). Renomear
// qualquer uma quebra o consumidor silenciosamente.
func TestEvaluationEvent_ContratoJsonComAnalyticsService(t *testing.T) {
	evento := EvaluationEvent{
		UserID:    "user-1",
		FlagName:  "checkout-novo",
		Result:    true,
		Timestamp: time.Date(2026, 1, 15, 10, 30, 0, 0, time.UTC),
	}

	corpo, err := json.Marshal(evento)
	if err != nil {
		t.Fatalf("falha ao serializar o evento: %v", err)
	}

	var decodificado map[string]interface{}
	if err := json.Unmarshal(corpo, &decodificado); err != nil {
		t.Fatalf("JSON inválido: %v", err)
	}

	for _, campo := range []string{"user_id", "flag_name", "result", "timestamp"} {
		if _, ok := decodificado[campo]; !ok {
			t.Errorf("campo %q ausente no evento — o analytics-service depende dele: %s", campo, corpo)
		}
	}

	if decodificado["flag_name"] != "checkout-novo" {
		t.Errorf("flag_name = %#v (é a partition key do Cosmos DB)", decodificado["flag_name"])
	}
	if decodificado["timestamp"] != "2026-01-15T10:30:00Z" {
		t.Errorf("timestamp = %#v, esperado RFC3339 em UTC", decodificado["timestamp"])
	}
}

func TestEvaluationEvent_RoundTrip(t *testing.T) {
	original := EvaluationEvent{
		UserID:    "user-42",
		FlagName:  "dark-mode",
		Result:    false,
		Timestamp: time.Now().UTC().Truncate(time.Second),
	}

	corpo, err := json.Marshal(original)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var voltou EvaluationEvent
	if err := json.Unmarshal(corpo, &voltou); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if voltou.UserID != original.UserID || voltou.FlagName != original.FlagName ||
		voltou.Result != original.Result || !voltou.Timestamp.Equal(original.Timestamp) {
		t.Errorf("round-trip perdeu dados: %+v != %+v", voltou, original)
	}
}
