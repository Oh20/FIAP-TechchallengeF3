package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// newTestApp devolve um App sem Redis e sem Service Bus, suficiente para
// exercitar a lógica de decisão e as chamadas HTTP aos outros microsserviços.
func newTestApp() *App {
	return &App{
		HttpClient: &http.Client{Timeout: 2 * time.Second},
	}
}

// --- getDeterministicBucket ---

func TestGetDeterministicBucket_SempreEntre0e99(t *testing.T) {
	for i := 0; i < 5000; i++ {
		entrada := fmt.Sprintf("user-%d:flag-x", i)
		bucket := getDeterministicBucket(entrada)

		if bucket < 0 || bucket > 99 {
			t.Fatalf("bucket de %q = %d, fora do intervalo [0,99]", entrada, bucket)
		}
	}
}

// O rollout percentual só é estável se o bucket do usuário nunca mudar.
func TestGetDeterministicBucket_EhDeterministico(t *testing.T) {
	const entrada = "usuario-123checkout-novo"

	primeiro := getDeterministicBucket(entrada)
	for i := 0; i < 50; i++ {
		if got := getDeterministicBucket(entrada); got != primeiro {
			t.Fatalf("bucket variou entre chamadas: %d != %d", got, primeiro)
		}
	}
}

func TestGetDeterministicBucket_EntradasDiferentesEspalham(t *testing.T) {
	vistos := make(map[int]struct{})
	for i := 0; i < 1000; i++ {
		vistos[getDeterministicBucket(fmt.Sprintf("user-%d", i))] = struct{}{}
	}

	// Com 1000 entradas e 100 buckets, esperar ao menos 80 buckets distintos é
	// folgado; menos que isso indica hash quebrado.
	if len(vistos) < 80 {
		t.Errorf("apenas %d buckets distintos em 1000 entradas — distribuição ruim", len(vistos))
	}
}

// --- runEvaluationLogic ---

func flagHabilitada(nome string) *Flag {
	return &Flag{ID: 1, Name: nome, Description: "flag de teste", IsEnabled: true}
}

func regraPercentual(nome string, valor interface{}, ativa bool) *TargetingRule {
	return &TargetingRule{
		ID:        1,
		FlagName:  nome,
		IsEnabled: ativa,
		Rules:     Rule{Type: "PERCENTAGE", Value: valor},
	}
}

func TestRunEvaluationLogic_FlagNulaRetornaFalse(t *testing.T) {
	app := newTestApp()

	if app.runEvaluationLogic(&CombinedFlagInfo{Flag: nil, Rule: nil}, "user-1") {
		t.Error("flag nula deveria resultar em false (comportamento seguro)")
	}
}

// Kill switch global: is_enabled=false desliga a flag para todo mundo.
func TestRunEvaluationLogic_FlagDesligadaIgnoraRegra(t *testing.T) {
	app := newTestApp()

	info := &CombinedFlagInfo{
		Flag: &Flag{Name: "checkout-novo", IsEnabled: false},
		Rule: regraPercentual("checkout-novo", float64(100), true),
	}

	if app.runEvaluationLogic(info, "user-1") {
		t.Error("flag desligada deveria retornar false mesmo com regra de 100%")
	}
}

func TestRunEvaluationLogic_SemRegraLiberaParaTodos(t *testing.T) {
	app := newTestApp()
	info := &CombinedFlagInfo{Flag: flagHabilitada("checkout-novo"), Rule: nil}

	for i := 0; i < 100; i++ {
		if !app.runEvaluationLogic(info, fmt.Sprintf("user-%d", i)) {
			t.Fatalf("flag ligada sem regra deveria liberar user-%d", i)
		}
	}
}

func TestRunEvaluationLogic_RegraDesativadaLiberaParaTodos(t *testing.T) {
	app := newTestApp()
	info := &CombinedFlagInfo{
		Flag: flagHabilitada("checkout-novo"),
		Rule: regraPercentual("checkout-novo", float64(0), false), // is_enabled = false
	}

	for i := 0; i < 100; i++ {
		if !app.runEvaluationLogic(info, fmt.Sprintf("user-%d", i)) {
			t.Fatalf("regra desativada deveria liberar user-%d", i)
		}
	}
}

func TestRunEvaluationLogic_Percentual100LiberaTodos(t *testing.T) {
	app := newTestApp()
	info := &CombinedFlagInfo{
		Flag: flagHabilitada("checkout-novo"),
		Rule: regraPercentual("checkout-novo", float64(100), true),
	}

	for i := 0; i < 500; i++ {
		if !app.runEvaluationLogic(info, fmt.Sprintf("user-%d", i)) {
			t.Fatalf("rollout de 100%% negou o user-%d", i)
		}
	}
}

func TestRunEvaluationLogic_Percentual0NegaTodos(t *testing.T) {
	app := newTestApp()
	info := &CombinedFlagInfo{
		Flag: flagHabilitada("checkout-novo"),
		Rule: regraPercentual("checkout-novo", float64(0), true),
	}

	for i := 0; i < 500; i++ {
		if app.runEvaluationLogic(info, fmt.Sprintf("user-%d", i)) {
			t.Fatalf("rollout de 0%% liberou o user-%d", i)
		}
	}
}

// Um rollout de 50% precisa cair perto de 50% da base — senão o hash está enviesado.
func TestRunEvaluationLogic_Percentual50FicaProximoDaMetade(t *testing.T) {
	app := newTestApp()
	info := &CombinedFlagInfo{
		Flag: flagHabilitada("checkout-novo"),
		Rule: regraPercentual("checkout-novo", float64(50), true),
	}

	const total = 5000
	liberados := 0
	for i := 0; i < total; i++ {
		if app.runEvaluationLogic(info, fmt.Sprintf("user-%d", i)) {
			liberados++
		}
	}

	percentual := float64(liberados) / float64(total) * 100
	if percentual < 45 || percentual > 55 {
		t.Errorf("rollout de 50%% liberou %.1f%% da base (esperado entre 45%% e 55%%)", percentual)
	}
}

// O mesmo usuário precisa ter sempre a mesma resposta — é o que evita a flag
// "piscando" entre requisições.
func TestRunEvaluationLogic_MesmoUsuarioMesmaDecisao(t *testing.T) {
	app := newTestApp()
	info := &CombinedFlagInfo{
		Flag: flagHabilitada("checkout-novo"),
		Rule: regraPercentual("checkout-novo", float64(50), true),
	}

	primeiro := app.runEvaluationLogic(info, "usuario-fixo")
	for i := 0; i < 100; i++ {
		if app.runEvaluationLogic(info, "usuario-fixo") != primeiro {
			t.Fatal("a decisão variou entre chamadas para o mesmo usuário")
		}
	}
}

// O bucket é calculado com userID+flagName: o mesmo usuário não pode cair
// sempre no mesmo lado em todas as flags.
func TestRunEvaluationLogic_BucketVariaPorFlag(t *testing.T) {
	app := newTestApp()

	decisoes := make(map[bool]int)
	for i := 0; i < 200; i++ {
		nome := fmt.Sprintf("flag-%d", i)
		info := &CombinedFlagInfo{
			Flag: flagHabilitada(nome),
			Rule: regraPercentual(nome, float64(50), true),
		}
		decisoes[app.runEvaluationLogic(info, "usuario-fixo")]++
	}

	if decisoes[true] == 0 || decisoes[false] == 0 {
		t.Errorf("o mesmo usuário teve sempre a mesma decisão em 200 flags: %v", decisoes)
	}
}

// JSON desserializa números como float64; qualquer outro tipo é configuração
// inválida e precisa falhar fechado.
func TestRunEvaluationLogic_ValorDePercentualInvalidoRetornaFalse(t *testing.T) {
	app := newTestApp()

	for _, valor := range []interface{}{"50", nil, true, []interface{}{50}} {
		info := &CombinedFlagInfo{
			Flag: flagHabilitada("checkout-novo"),
			Rule: regraPercentual("checkout-novo", valor, true),
		}
		if app.runEvaluationLogic(info, "user-1") {
			t.Errorf("valor inválido %#v deveria resultar em false", valor)
		}
	}
}

func TestRunEvaluationLogic_TipoDeRegraDesconhecidoRetornaFalse(t *testing.T) {
	app := newTestApp()

	info := &CombinedFlagInfo{
		Flag: flagHabilitada("checkout-novo"),
		Rule: &TargetingRule{
			FlagName:  "checkout-novo",
			IsEnabled: true,
			Rules:     Rule{Type: "USER_LIST", Value: []interface{}{"u1"}},
		},
	}

	if app.runEvaluationLogic(info, "u1") {
		t.Error("tipo de regra não suportado deveria resultar em false")
	}
}

// --- fetchFlag / fetchRule ---

func servidorFake(t *testing.T, status int, corpo string, capturaAuth *string) *httptest.Server {
	t.Helper()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if capturaAuth != nil {
			*capturaAuth = r.Header.Get("Authorization")
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(corpo))
	}))
	t.Cleanup(srv.Close)
	return srv
}

func TestFetchFlag_RespostaOkEhDesserializada(t *testing.T) {
	srv := servidorFake(t, http.StatusOK,
		`{"id":1,"name":"checkout-novo","description":"novo fluxo","is_enabled":true}`, nil)

	app := newTestApp()
	app.FlagServiceURL = srv.URL

	flag, err := app.fetchFlag("checkout-novo")
	if err != nil {
		t.Fatalf("fetchFlag devolveu erro: %v", err)
	}
	if flag.Name != "checkout-novo" || !flag.IsEnabled || flag.ID != 1 {
		t.Errorf("flag desserializada incorretamente: %+v", flag)
	}
}

// O evaluation-service precisa propagar a SERVICE_API_KEY, senão o flag-service
// devolve 401 (foi o bug de "vazamento de contexto de autenticação" da fase 2).
func TestFetchFlag_EnviaServiceApiKeyNoHeader(t *testing.T) {
	var authRecebido string
	srv := servidorFake(t, http.StatusOK, `{"name":"x","is_enabled":true}`, &authRecebido)

	t.Setenv("SERVICE_API_KEY", "tm_key_do_servico")

	app := newTestApp()
	app.FlagServiceURL = srv.URL

	if _, err := app.fetchFlag("x"); err != nil {
		t.Fatalf("fetchFlag devolveu erro: %v", err)
	}
	if authRecebido != "Bearer tm_key_do_servico" {
		t.Errorf("Authorization recebido = %q, esperado \"Bearer tm_key_do_servico\"", authRecebido)
	}
}

func TestFetchFlag_404ViraNotFoundError(t *testing.T) {
	srv := servidorFake(t, http.StatusNotFound, `{"error":"Flag não encontrada"}`, nil)

	app := newTestApp()
	app.FlagServiceURL = srv.URL

	_, err := app.fetchFlag("inexistente")
	if err == nil {
		t.Fatal("fetchFlag deveria devolver erro para 404")
	}
	nfe, ok := err.(*NotFoundError)
	if !ok {
		t.Fatalf("erro deveria ser *NotFoundError, veio %T (%v)", err, err)
	}
	if nfe.FlagName != "inexistente" {
		t.Errorf("FlagName = %q, esperado \"inexistente\"", nfe.FlagName)
	}
}

func TestFetchFlag_Status500ViraErroGenerico(t *testing.T) {
	srv := servidorFake(t, http.StatusInternalServerError, `{"error":"boom"}`, nil)

	app := newTestApp()
	app.FlagServiceURL = srv.URL

	_, err := app.fetchFlag("x")
	if err == nil {
		t.Fatal("fetchFlag deveria devolver erro para 500")
	}
	if _, ok := err.(*NotFoundError); ok {
		t.Error("500 não deveria virar NotFoundError — é falha de infraestrutura, não flag ausente")
	}
}

func TestFetchFlag_JsonInvalidoRetornaErro(t *testing.T) {
	srv := servidorFake(t, http.StatusOK, `{isso não é json}`, nil)

	app := newTestApp()
	app.FlagServiceURL = srv.URL

	if _, err := app.fetchFlag("x"); err == nil {
		t.Fatal("fetchFlag deveria devolver erro para JSON inválido")
	}
}

func TestFetchFlag_ServicoIndisponivelRetornaErro(t *testing.T) {
	app := newTestApp()
	// Porta reservada para "descarte": a conexão falha imediatamente.
	app.FlagServiceURL = "http://127.0.0.1:9"

	if _, err := app.fetchFlag("x"); err == nil {
		t.Fatal("fetchFlag deveria devolver erro quando o flag-service está fora")
	}
}

func TestFetchRule_RespostaOkEhDesserializada(t *testing.T) {
	srv := servidorFake(t, http.StatusOK,
		`{"id":9,"flag_name":"checkout-novo","is_enabled":true,"rules":{"type":"PERCENTAGE","value":25}}`, nil)

	app := newTestApp()
	app.TargetingServiceURL = srv.URL

	regra, err := app.fetchRule("checkout-novo")
	if err != nil {
		t.Fatalf("fetchRule devolveu erro: %v", err)
	}
	if regra.Rules.Type != "PERCENTAGE" {
		t.Errorf("tipo da regra = %q, esperado \"PERCENTAGE\"", regra.Rules.Type)
	}
	if valor, ok := regra.Rules.Value.(float64); !ok || valor != 25 {
		t.Errorf("valor da regra = %#v, esperado float64(25)", regra.Rules.Value)
	}
}

func TestFetchRule_404ViraNotFoundError(t *testing.T) {
	srv := servidorFake(t, http.StatusNotFound, `{"error":"Regra não encontrada"}`, nil)

	app := newTestApp()
	app.TargetingServiceURL = srv.URL

	_, err := app.fetchRule("sem-regra")
	if _, ok := err.(*NotFoundError); !ok {
		t.Fatalf("erro deveria ser *NotFoundError, veio %T (%v)", err, err)
	}
}

// --- fetchFromServices ---

func TestFetchFromServices_CombinaFlagERegra(t *testing.T) {
	flagSrv := servidorFake(t, http.StatusOK, `{"name":"checkout-novo","is_enabled":true}`, nil)
	ruleSrv := servidorFake(t, http.StatusOK,
		`{"flag_name":"checkout-novo","is_enabled":true,"rules":{"type":"PERCENTAGE","value":50}}`, nil)

	app := newTestApp()
	app.FlagServiceURL = flagSrv.URL
	app.TargetingServiceURL = ruleSrv.URL

	info, err := app.fetchFromServices("checkout-novo")
	if err != nil {
		t.Fatalf("fetchFromServices devolveu erro: %v", err)
	}
	if info.Flag == nil || info.Rule == nil {
		t.Fatalf("flag e regra deveriam estar preenchidas: %+v", info)
	}
}

// Regra ausente não é erro fatal: a flag simplesmente vale para todos.
func TestFetchFromServices_SemRegraNaoEhErro(t *testing.T) {
	flagSrv := servidorFake(t, http.StatusOK, `{"name":"checkout-novo","is_enabled":true}`, nil)
	ruleSrv := servidorFake(t, http.StatusNotFound, `{"error":"Regra não encontrada"}`, nil)

	app := newTestApp()
	app.FlagServiceURL = flagSrv.URL
	app.TargetingServiceURL = ruleSrv.URL

	info, err := app.fetchFromServices("checkout-novo")
	if err != nil {
		t.Fatalf("regra ausente não deveria virar erro: %v", err)
	}
	if info.Rule != nil {
		t.Errorf("Rule deveria ser nil, veio %+v", info.Rule)
	}
	if !app.runEvaluationLogic(info, "user-1") {
		t.Error("flag ligada sem regra deveria liberar o usuário")
	}
}

// Flag ausente, ao contrário da regra, aborta a busca.
func TestFetchFromServices_FlagAusenteRetornaErro(t *testing.T) {
	flagSrv := servidorFake(t, http.StatusNotFound, `{"error":"Flag não encontrada"}`, nil)
	ruleSrv := servidorFake(t, http.StatusNotFound, `{"error":"Regra não encontrada"}`, nil)

	app := newTestApp()
	app.FlagServiceURL = flagSrv.URL
	app.TargetingServiceURL = ruleSrv.URL

	_, err := app.fetchFromServices("inexistente")
	if _, ok := err.(*NotFoundError); !ok {
		t.Fatalf("erro deveria ser *NotFoundError, veio %T (%v)", err, err)
	}
}
