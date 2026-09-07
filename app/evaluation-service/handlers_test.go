package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHealthHandler_RespondeOkComContentTypeJson(t *testing.T) {
	app := newTestApp()

	rec := httptest.NewRecorder()
	app.healthHandler(rec, httptest.NewRequest(http.MethodGet, "/health", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, esperado %d", rec.Code, http.StatusOK)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("Content-Type = %q, esperado \"application/json\"", ct)
	}

	var body map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("resposta não é JSON válido (%q): %v", rec.Body.String(), err)
	}
	if body["status"] != "ok" {
		t.Errorf("status no corpo = %q, esperado \"ok\"", body["status"])
	}
}

// O /health precisa responder mesmo sem Redis e sem Service Bus configurados —
// é ele que sustenta as probes do Kubernetes durante o startup.
func TestHealthHandler_FuncionaSemDependencias(t *testing.T) {
	app := &App{} // sem Redis, sem Service Bus, sem HttpClient

	rec := httptest.NewRecorder()
	app.healthHandler(rec, httptest.NewRequest(http.MethodGet, "/health", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, esperado %d", rec.Code, http.StatusOK)
	}
}

func TestEvaluationHandler_ParametrosObrigatorios(t *testing.T) {
	casos := []struct {
		nome  string
		query string
	}{
		{"sem nenhum parâmetro", ""},
		{"sem flag_name", "?user_id=user-1"},
		{"sem user_id", "?flag_name=checkout-novo"},
		{"user_id vazio", "?user_id=&flag_name=checkout-novo"},
		{"flag_name vazio", "?user_id=user-1&flag_name="},
	}

	for _, caso := range casos {
		t.Run(caso.nome, func(t *testing.T) {
			// App sem Redis de propósito: a validação precisa barrar a requisição
			// ANTES de tocar em qualquer dependência externa.
			app := &App{}

			rec := httptest.NewRecorder()
			app.evaluationHandler(rec, httptest.NewRequest(http.MethodGet, "/evaluate"+caso.query, nil))

			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, esperado %d (corpo: %s)", rec.Code, http.StatusBadRequest, rec.Body.String())
			}
			if !strings.Contains(rec.Body.String(), "user_id") {
				t.Errorf("a mensagem de erro deveria citar os parâmetros obrigatórios, veio: %s", rec.Body.String())
			}
		})
	}
}

func TestEvaluationResponse_ContratoJson(t *testing.T) {
	corpo, err := json.Marshal(EvaluationResponse{
		FlagName: "checkout-novo",
		UserID:   "user-1",
		Result:   true,
	})
	if err != nil {
		t.Fatalf("falha ao serializar EvaluationResponse: %v", err)
	}

	var decodificado map[string]interface{}
	if err := json.Unmarshal(corpo, &decodificado); err != nil {
		t.Fatalf("JSON inválido: %v", err)
	}

	// Os SDKs clientes dependem exatamente destes nomes de campo.
	for _, campo := range []string{"flag_name", "user_id", "result"} {
		if _, ok := decodificado[campo]; !ok {
			t.Errorf("campo %q ausente na resposta: %s", campo, corpo)
		}
	}
	if decodificado["result"] != true {
		t.Errorf("result = %#v, esperado true", decodificado["result"])
	}
}
