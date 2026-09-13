package main

// cache_test.go — cobre o caminho quente do serviço: cache Redis + decisão.
//
// Usa o miniredis, um servidor Redis in-process escrito em Go. Não sobe
// container, não abre porta fixa e some no fim do teste — continua sendo um
// teste unitário, não de integração.

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/go-redis/redis/v8"
)

// servidorContado devolve um httptest.Server que conta quantas requisições
// recebeu — é assim que verificamos se o cache realmente evitou a chamada.
func servidorContado(t *testing.T, corpo string) (*httptest.Server, *int32) {
	t.Helper()

	var chamadas int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&chamadas, 1)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(corpo))
	}))
	t.Cleanup(srv.Close)

	return srv, &chamadas
}

// appComCache monta um App com Redis in-process e os dois serviços dublados.
func appComCache(t *testing.T, corpoFlag, corpoRegra string) (*App, *miniredis.Miniredis, *int32, *int32) {
	t.Helper()

	servidorRedis := miniredis.RunT(t)

	flagSrv, chamadasFlag := servidorContado(t, corpoFlag)
	ruleSrv, chamadasRegra := servidorContado(t, corpoRegra)

	app := &App{
		RedisClient:         redis.NewClient(&redis.Options{Addr: servidorRedis.Addr()}),
		HttpClient:          &http.Client{Timeout: 2 * time.Second},
		FlagServiceURL:      flagSrv.URL,
		TargetingServiceURL: ruleSrv.URL,
	}
	t.Cleanup(func() { _ = app.RedisClient.Close() })

	return app, servidorRedis, chamadasFlag, chamadasRegra
}

const (
	corpoFlagLigada  = `{"id":1,"name":"checkout-novo","description":"novo fluxo","is_enabled":true}`
	corpoRegra50     = `{"id":7,"flag_name":"checkout-novo","is_enabled":true,"rules":{"type":"PERCENTAGE","value":50}}`
	corpoRegra100    = `{"id":7,"flag_name":"checkout-novo","is_enabled":true,"rules":{"type":"PERCENTAGE","value":100}}`
	chaveCacheFlag   = "flag_info:checkout-novo"
)

// --- getCombinedFlagInfo ---

func TestGetCombinedFlagInfo_CacheMissBuscaNosServicos(t *testing.T) {
	app, servidorRedis, chamadasFlag, chamadasRegra := appComCache(t, corpoFlagLigada, corpoRegra50)

	info, err := app.getCombinedFlagInfo("checkout-novo")
	if err != nil {
		t.Fatalf("getCombinedFlagInfo devolveu erro: %v", err)
	}

	if info.Flag == nil || info.Flag.Name != "checkout-novo" {
		t.Fatalf("flag não veio dos serviços: %+v", info.Flag)
	}
	if atomic.LoadInt32(chamadasFlag) != 1 || atomic.LoadInt32(chamadasRegra) != 1 {
		t.Errorf("esperava 1 chamada a cada serviço, veio flag=%d regra=%d",
			*chamadasFlag, *chamadasRegra)
	}

	if !servidorRedis.Exists(chaveCacheFlag) {
		t.Error("o resultado não foi gravado no cache")
	}
}

func TestGetCombinedFlagInfo_CacheHitNaoChamaOsServicos(t *testing.T) {
	app, _, chamadasFlag, chamadasRegra := appComCache(t, corpoFlagLigada, corpoRegra50)

	// Primeira chamada popula o cache.
	if _, err := app.getCombinedFlagInfo("checkout-novo"); err != nil {
		t.Fatalf("primeira chamada falhou: %v", err)
	}

	// As próximas 10 precisam sair do Redis.
	for i := 0; i < 10; i++ {
		if _, err := app.getCombinedFlagInfo("checkout-novo"); err != nil {
			t.Fatalf("chamada %d falhou: %v", i, err)
		}
	}

	if got := atomic.LoadInt32(chamadasFlag); got != 1 {
		t.Errorf("flag-service foi chamado %d vezes — o cache não segurou", got)
	}
	if got := atomic.LoadInt32(chamadasRegra); got != 1 {
		t.Errorf("targeting-service foi chamado %d vezes — o cache não segurou", got)
	}
}

func TestGetCombinedFlagInfo_CacheAplicaTtl(t *testing.T) {
	app, servidorRedis, _, _ := appComCache(t, corpoFlagLigada, corpoRegra50)

	if _, err := app.getCombinedFlagInfo("checkout-novo"); err != nil {
		t.Fatalf("getCombinedFlagInfo: %v", err)
	}

	// Sem TTL o cache nunca expiraria e uma flag desligada continuaria valendo.
	if ttl := servidorRedis.TTL(chaveCacheFlag); ttl != CACHE_TTL {
		t.Errorf("TTL da chave de cache = %v, esperado %v", ttl, CACHE_TTL)
	}
}

func TestGetCombinedFlagInfo_CacheExpiradoRebuscaNosServicos(t *testing.T) {
	app, servidorRedis, chamadasFlag, _ := appComCache(t, corpoFlagLigada, corpoRegra50)

	if _, err := app.getCombinedFlagInfo("checkout-novo"); err != nil {
		t.Fatalf("primeira chamada: %v", err)
	}

	// Avança o relógio do miniredis para além do TTL.
	servidorRedis.FastForward(CACHE_TTL + time.Second)

	if _, err := app.getCombinedFlagInfo("checkout-novo"); err != nil {
		t.Fatalf("segunda chamada: %v", err)
	}

	if got := atomic.LoadInt32(chamadasFlag); got != 2 {
		t.Errorf("após o TTL expirar esperava 2 chamadas ao flag-service, veio %d", got)
	}
}

// Cache corrompido não pode derrubar o serviço — deve virar um cache MISS.
func TestGetCombinedFlagInfo_CacheCorrompidoViraMiss(t *testing.T) {
	app, servidorRedis, chamadasFlag, _ := appComCache(t, corpoFlagLigada, corpoRegra50)

	if err := servidorRedis.Set(chaveCacheFlag, "{{{ isso não é json"); err != nil {
		t.Fatalf("não foi possível plantar o cache corrompido: %v", err)
	}

	info, err := app.getCombinedFlagInfo("checkout-novo")
	if err != nil {
		t.Fatalf("cache corrompido deveria virar MISS, mas devolveu erro: %v", err)
	}
	if info.Flag == nil || info.Flag.Name != "checkout-novo" {
		t.Fatalf("os serviços não foram consultados após o cache corrompido: %+v", info)
	}
	if atomic.LoadInt32(chamadasFlag) != 1 {
		t.Errorf("esperava 1 chamada ao flag-service, veio %d", *chamadasFlag)
	}
}

// O que vai para o Redis precisa ser o CombinedFlagInfo serializado.
func TestGetCombinedFlagInfo_ConteudoGravadoNoCache(t *testing.T) {
	app, servidorRedis, _, _ := appComCache(t, corpoFlagLigada, corpoRegra50)

	if _, err := app.getCombinedFlagInfo("checkout-novo"); err != nil {
		t.Fatalf("getCombinedFlagInfo: %v", err)
	}

	bruto, err := servidorRedis.Get(chaveCacheFlag)
	if err != nil {
		t.Fatalf("chave de cache não encontrada: %v", err)
	}

	var info CombinedFlagInfo
	if err := json.Unmarshal([]byte(bruto), &info); err != nil {
		t.Fatalf("o conteúdo do cache não é um CombinedFlagInfo válido: %v", err)
	}
	if info.Flag == nil || !info.Flag.IsEnabled {
		t.Errorf("flag gravada incorretamente no cache: %+v", info.Flag)
	}
	if info.Rule == nil || info.Rule.Rules.Type != "PERCENTAGE" {
		t.Errorf("regra gravada incorretamente no cache: %+v", info.Rule)
	}
}

// --- getDecision ---

func TestGetDecision_FlagLigadaComRollout100(t *testing.T) {
	app, _, _, _ := appComCache(t, corpoFlagLigada, corpoRegra100)

	decisao, err := app.getDecision("user-1", "checkout-novo")
	if err != nil {
		t.Fatalf("getDecision devolveu erro: %v", err)
	}
	if !decisao {
		t.Error("rollout de 100% deveria liberar o usuário")
	}
}

func TestGetDecision_FlagDesligada(t *testing.T) {
	app, _, _, _ := appComCache(t,
		`{"id":1,"name":"checkout-novo","is_enabled":false}`, corpoRegra100)

	decisao, err := app.getDecision("user-1", "checkout-novo")
	if err != nil {
		t.Fatalf("getDecision devolveu erro: %v", err)
	}
	if decisao {
		t.Error("flag desligada deveria negar mesmo com rollout de 100%")
	}
}

// A decisão precisa ser idêntica vindo do cache ou dos serviços.
func TestGetDecision_EstavelEntreCacheEServicos(t *testing.T) {
	app, servidorRedis, _, _ := appComCache(t, corpoFlagLigada, corpoRegra50)

	usuarios := []string{"user-1", "user-2", "user-3", "user-42", "user-99"}

	primeiras := make(map[string]bool, len(usuarios))
	for _, u := range usuarios {
		d, err := app.getDecision(u, "checkout-novo")
		if err != nil {
			t.Fatalf("getDecision(%s): %v", u, err)
		}
		primeiras[u] = d
	}

	// Agora tudo vem do cache.
	if !servidorRedis.Exists(chaveCacheFlag) {
		t.Fatal("o cache deveria estar populado neste ponto")
	}
	for _, u := range usuarios {
		d, err := app.getDecision(u, "checkout-novo")
		if err != nil {
			t.Fatalf("getDecision(%s) via cache: %v", u, err)
		}
		if d != primeiras[u] {
			t.Errorf("decisão para %s mudou ao vir do cache: %v -> %v", u, primeiras[u], d)
		}
	}
}

func TestGetDecision_FlagInexistenteRetornaNotFound(t *testing.T) {
	servidorRedis := miniredis.RunT(t)

	flagSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	t.Cleanup(flagSrv.Close)

	ruleSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	t.Cleanup(ruleSrv.Close)

	app := &App{
		RedisClient:         redis.NewClient(&redis.Options{Addr: servidorRedis.Addr()}),
		HttpClient:          &http.Client{Timeout: 2 * time.Second},
		FlagServiceURL:      flagSrv.URL,
		TargetingServiceURL: ruleSrv.URL,
	}
	t.Cleanup(func() { _ = app.RedisClient.Close() })

	_, err := app.getDecision("user-1", "inexistente")
	if _, ok := err.(*NotFoundError); !ok {
		t.Fatalf("erro deveria ser *NotFoundError, veio %T (%v)", err, err)
	}
}

// --- evaluationHandler (caminho feliz, ponta a ponta) ---

func TestEvaluationHandler_RespondeComADecisao(t *testing.T) {
	app, _, _, _ := appComCache(t, corpoFlagLigada, corpoRegra100)

	req := httptest.NewRequest(http.MethodGet, "/evaluate?user_id=user-1&flag_name=checkout-novo", nil)
	rec := httptest.NewRecorder()
	app.evaluationHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, esperado %d (corpo: %s)", rec.Code, http.StatusOK, rec.Body.String())
	}

	var resposta EvaluationResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resposta); err != nil {
		t.Fatalf("resposta não é JSON válido (%q): %v", rec.Body.String(), err)
	}

	if resposta.FlagName != "checkout-novo" || resposta.UserID != "user-1" || !resposta.Result {
		t.Errorf("resposta incorreta: %+v", resposta)
	}
}

// Flag inexistente devolve 200 com result=false (falha segura), não 404/502.
func TestEvaluationHandler_FlagInexistenteRetorna200ComFalse(t *testing.T) {
	servidorRedis := miniredis.RunT(t)

	naoEncontrado := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	t.Cleanup(naoEncontrado.Close)

	app := &App{
		RedisClient:         redis.NewClient(&redis.Options{Addr: servidorRedis.Addr()}),
		HttpClient:          &http.Client{Timeout: 2 * time.Second},
		FlagServiceURL:      naoEncontrado.URL,
		TargetingServiceURL: naoEncontrado.URL,
	}
	t.Cleanup(func() { _ = app.RedisClient.Close() })

	req := httptest.NewRequest(http.MethodGet, "/evaluate?user_id=user-1&flag_name=nao-existe", nil)
	rec := httptest.NewRecorder()
	app.evaluationHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, esperado 200 (corpo: %s)", rec.Code, rec.Body.String())
	}

	var resposta EvaluationResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resposta); err != nil {
		t.Fatalf("resposta não é JSON válido: %v", err)
	}
	if resposta.Result {
		t.Error("flag inexistente deveria resultar em false")
	}
}

// Serviços fora do ar são erro de infraestrutura: 502, não uma decisão falsa.
func TestEvaluationHandler_ServicosForaDoArRetorna502(t *testing.T) {
	servidorRedis := miniredis.RunT(t)

	app := &App{
		RedisClient:         redis.NewClient(&redis.Options{Addr: servidorRedis.Addr()}),
		HttpClient:          &http.Client{Timeout: 2 * time.Second},
		FlagServiceURL:      "http://127.0.0.1:9", // porta de descarte
		TargetingServiceURL: "http://127.0.0.1:9",
	}
	t.Cleanup(func() { _ = app.RedisClient.Close() })

	req := httptest.NewRequest(http.MethodGet, "/evaluate?user_id=user-1&flag_name=checkout-novo", nil)
	rec := httptest.NewRecorder()
	app.evaluationHandler(rec, req)

	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status = %d, esperado %d (corpo: %s)", rec.Code, http.StatusBadGateway, rec.Body.String())
	}
}

// Flags diferentes usam chaves de cache diferentes.
func TestGetCombinedFlagInfo_ChaveDeCachePorFlag(t *testing.T) {
	app, servidorRedis, _, _ := appComCache(t, corpoFlagLigada, corpoRegra50)

	for _, nome := range []string{"checkout-novo", "dark-mode", "nova-busca"} {
		if _, err := app.getCombinedFlagInfo(nome); err != nil {
			t.Fatalf("getCombinedFlagInfo(%s): %v", nome, err)
		}
		chave := fmt.Sprintf("flag_info:%s", nome)
		if !servidorRedis.Exists(chave) {
			t.Errorf("chave de cache %q não foi criada", chave)
		}
	}
}
