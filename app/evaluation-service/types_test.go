package main

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestNotFoundError_MensagemCitaAFlag(t *testing.T) {
	err := &NotFoundError{FlagName: "checkout-novo"}

	if !strings.Contains(err.Error(), "checkout-novo") {
		t.Errorf("mensagem = %q, deveria citar o nome da flag", err.Error())
	}
}

// O handler faz type assertion para *NotFoundError e devolve `false` em vez de
// 502. Se o erro deixar de satisfazer a interface `error`, esse caminho quebra.
func TestNotFoundError_SatisfazInterfaceError(t *testing.T) {
	var err error = &NotFoundError{FlagName: "x"}

	var alvo *NotFoundError
	if !errors.As(err, &alvo) {
		t.Fatal("*NotFoundError deveria ser recuperável via errors.As")
	}
	if alvo.FlagName != "x" {
		t.Errorf("FlagName = %q, esperado \"x\"", alvo.FlagName)
	}
}

// Estrutura gravada no Redis: precisa sobreviver ao marshal/unmarshal, senão
// todo cache HIT vira MISS silencioso.
func TestCombinedFlagInfo_SobreviveAoCacheRedis(t *testing.T) {
	original := &CombinedFlagInfo{
		Flag: &Flag{ID: 1, Name: "checkout-novo", Description: "novo fluxo", IsEnabled: true},
		Rule: &TargetingRule{
			ID:        7,
			FlagName:  "checkout-novo",
			IsEnabled: true,
			Rules:     Rule{Type: "PERCENTAGE", Value: float64(30)},
		},
	}

	serializado, err := json.Marshal(original)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var voltou CombinedFlagInfo
	if err := json.Unmarshal(serializado, &voltou); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if voltou.Flag == nil || voltou.Flag.Name != "checkout-novo" || !voltou.Flag.IsEnabled {
		t.Fatalf("flag corrompida no round-trip: %+v", voltou.Flag)
	}
	if voltou.Rule == nil || voltou.Rule.Rules.Type != "PERCENTAGE" {
		t.Fatalf("regra corrompida no round-trip: %+v", voltou.Rule)
	}

	// O valor volta como float64 — é exatamente o que runEvaluationLogic espera.
	valor, ok := voltou.Rule.Rules.Value.(float64)
	if !ok || valor != 30 {
		t.Errorf("valor da regra após o cache = %#v (%T), esperado float64(30)",
			voltou.Rule.Rules.Value, voltou.Rule.Rules.Value)
	}

	// E a decisão precisa ser a mesma antes e depois do cache.
	app := newTestApp()
	for _, user := range []string{"user-1", "user-2", "user-3", "user-99"} {
		if app.runEvaluationLogic(original, user) != app.runEvaluationLogic(&voltou, user) {
			t.Errorf("a decisão para %q mudou depois de passar pelo cache", user)
		}
	}
}

// A resposta do flag-service usa snake_case; o unmarshal precisa acertar as tags.
func TestFlag_DesserializaRespostaDoFlagService(t *testing.T) {
	payload := `{"id":3,"name":"dark-mode","description":"tema escuro","is_enabled":true}`

	var flag Flag
	if err := json.Unmarshal([]byte(payload), &flag); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if flag.ID != 3 || flag.Name != "dark-mode" || flag.Description != "tema escuro" || !flag.IsEnabled {
		t.Errorf("flag desserializada incorretamente: %+v", flag)
	}
}

func TestTargetingRule_DesserializaRegraJsonb(t *testing.T) {
	payload := `{"id":5,"flag_name":"dark-mode","is_enabled":true,"rules":{"type":"PERCENTAGE","value":75}}`

	var regra TargetingRule
	if err := json.Unmarshal([]byte(payload), &regra); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if regra.FlagName != "dark-mode" || !regra.IsEnabled {
		t.Errorf("regra desserializada incorretamente: %+v", regra)
	}
	if regra.Rules.Type != "PERCENTAGE" {
		t.Errorf("tipo = %q, esperado \"PERCENTAGE\"", regra.Rules.Type)
	}
	if valor, ok := regra.Rules.Value.(float64); !ok || valor != 75 {
		t.Errorf("valor = %#v, esperado float64(75)", regra.Rules.Value)
	}
}
