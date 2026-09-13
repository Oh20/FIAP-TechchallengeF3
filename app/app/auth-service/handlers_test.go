package main

import (
	"bytes"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const masterKeyDeTeste = "master-key-de-teste"

// newTestApp devolve um App ligado ao driver fake e o roteiro do "banco".
func newTestApp(t *testing.T) (*App, *fakeDB) {
	t.Helper()

	db, script, err := newFakeDB()
	if err != nil {
		t.Fatalf("não foi possível abrir o banco fake: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	return &App{DB: db, MasterKey: masterKeyDeTeste}, script
}

func decodeJSON(t *testing.T, rec *httptest.ResponseRecorder, alvo interface{}) {
	t.Helper()
	if err := json.Unmarshal(rec.Body.Bytes(), alvo); err != nil {
		t.Fatalf("resposta não é JSON válido (%q): %v", rec.Body.String(), err)
	}
}

// --- /health ---

func TestHealthHandler_RespondeOk(t *testing.T) {
	app, _ := newTestApp(t)

	rec := httptest.NewRecorder()
	app.healthHandler(rec, httptest.NewRequest(http.MethodGet, "/health", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, esperado %d", rec.Code, http.StatusOK)
	}

	var body map[string]string
	decodeJSON(t, rec, &body)
	if body["status"] != "ok" {
		t.Errorf("status no corpo = %q, esperado \"ok\"", body["status"])
	}
}

// --- /validate ---

func TestValidateKeyHandler_SemHeaderRetorna401(t *testing.T) {
	app, script := newTestApp(t)

	rec := httptest.NewRecorder()
	app.validateKeyHandler(rec, httptest.NewRequest(http.MethodGet, "/validate", nil))

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, esperado %d", rec.Code, http.StatusUnauthorized)
	}
	if script.callCount() != 0 {
		t.Errorf("o banco não deveria ser consultado sem header, houve %d query(ies)", script.callCount())
	}
}

func TestValidateKeyHandler_ChaveValidaRetorna200(t *testing.T) {
	app, script := newTestApp(t)

	// O banco encontra a linha: devolve o id.
	script.cols = []string{"id"}
	script.rows = [][]driver.Value{{int64(42)}}

	const chave = "tm_key_valida"
	req := httptest.NewRequest(http.MethodGet, "/validate", nil)
	req.Header.Set("Authorization", "Bearer "+chave)

	rec := httptest.NewRecorder()
	app.validateKeyHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, esperado %d (corpo: %s)", rec.Code, http.StatusOK, rec.Body.String())
	}

	var body map[string]string
	decodeJSON(t, rec, &body)
	if body["message"] == "" {
		t.Error("resposta de sucesso deveria conter a mensagem de chave válida")
	}
}

// A chave em texto plano NUNCA pode ir para o banco — só o hash SHA-256.
func TestValidateKeyHandler_ConsultaPeloHashENaoPelaChave(t *testing.T) {
	app, script := newTestApp(t)
	script.cols = []string{"id"}
	script.rows = [][]driver.Value{{int64(1)}}

	const chave = "tm_key_segredo"
	req := httptest.NewRequest(http.MethodGet, "/validate", nil)
	req.Header.Set("Authorization", "Bearer "+chave)

	app.validateKeyHandler(httptest.NewRecorder(), req)

	args := script.lastArgs()
	if len(args) != 1 {
		t.Fatalf("esperava 1 argumento na query, veio %d (%v)", len(args), args)
	}

	recebido, ok := args[0].(string)
	if !ok {
		t.Fatalf("argumento deveria ser string, veio %T", args[0])
	}
	if recebido != hashAPIKey(chave) {
		t.Errorf("query recebeu %q, esperado o hash %q", recebido, hashAPIKey(chave))
	}
	if strings.Contains(recebido, chave) {
		t.Error("a chave em texto plano vazou para a query do banco")
	}

	if !strings.Contains(script.lastQuery(), "is_active = true") {
		t.Errorf("a query deveria filtrar chaves inativas, veio: %q", script.lastQuery())
	}
}

func TestValidateKeyHandler_ChaveInexistenteRetorna401(t *testing.T) {
	app, script := newTestApp(t)

	// Nenhuma linha => QueryRow devolve sql.ErrNoRows.
	script.cols = []string{"id"}
	script.rows = nil

	req := httptest.NewRequest(http.MethodGet, "/validate", nil)
	req.Header.Set("Authorization", "Bearer tm_key_inexistente")

	rec := httptest.NewRecorder()
	app.validateKeyHandler(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, esperado %d", rec.Code, http.StatusUnauthorized)
	}
}

// Falha de infraestrutura no banco também precisa negar o acesso (fail-closed).
func TestValidateKeyHandler_ErroDeBancoRetorna401(t *testing.T) {
	app, script := newTestApp(t)
	script.err = errors.New("conexão recusada")

	req := httptest.NewRequest(http.MethodGet, "/validate", nil)
	req.Header.Set("Authorization", "Bearer tm_key_qualquer")

	rec := httptest.NewRecorder()
	app.validateKeyHandler(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, esperado %d", rec.Code, http.StatusUnauthorized)
	}
}

// O handler usa TrimPrefix: um header sem "Bearer " é tratado como a chave crua.
func TestValidateKeyHandler_HeaderSemBearerUsaValorCru(t *testing.T) {
	app, script := newTestApp(t)
	script.cols = []string{"id"}
	script.rows = [][]driver.Value{{int64(7)}}

	const chave = "tm_key_sem_bearer"
	req := httptest.NewRequest(http.MethodGet, "/validate", nil)
	req.Header.Set("Authorization", chave)

	rec := httptest.NewRecorder()
	app.validateKeyHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, esperado %d", rec.Code, http.StatusOK)
	}
	if got := script.lastArgs()[0]; got != hashAPIKey(chave) {
		t.Errorf("query recebeu %v, esperado o hash de %q", got, chave)
	}
}

// --- /admin/keys ---

func postCreateKey(t *testing.T, corpo string) *http.Request {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/admin/keys", bytes.NewBufferString(corpo))
	req.Header.Set("Content-Type", "application/json")
	return req
}

func TestCreateKeyHandler_MetodoInvalidoRetorna405(t *testing.T) {
	app, _ := newTestApp(t)

	rec := httptest.NewRecorder()
	app.createKeyHandler(rec, httptest.NewRequest(http.MethodGet, "/admin/keys", nil))

	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, esperado %d", rec.Code, http.StatusMethodNotAllowed)
	}
}

func TestCreateKeyHandler_CorpoInvalidoRetorna400(t *testing.T) {
	app, _ := newTestApp(t)

	rec := httptest.NewRecorder()
	app.createKeyHandler(rec, postCreateKey(t, "isso-não-é-json"))

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, esperado %d", rec.Code, http.StatusBadRequest)
	}
}

func TestCreateKeyHandler_NomeVazioRetorna400(t *testing.T) {
	app, script := newTestApp(t)

	rec := httptest.NewRecorder()
	app.createKeyHandler(rec, postCreateKey(t, `{"name": ""}`))

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, esperado %d", rec.Code, http.StatusBadRequest)
	}
	if script.callCount() != 0 {
		t.Error("não deveria tocar no banco com nome vazio")
	}
}

func TestCreateKeyHandler_SucessoRetorna201ComChaveEmTextoPlano(t *testing.T) {
	app, script := newTestApp(t)
	script.cols = []string{"id"}
	script.rows = [][]driver.Value{{int64(99)}}

	rec := httptest.NewRecorder()
	app.createKeyHandler(rec, postCreateKey(t, `{"name": "pipeline-ci"}`))

	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, esperado %d (corpo: %s)", rec.Code, http.StatusCreated, rec.Body.String())
	}

	var resp CreateKeyResponse
	decodeJSON(t, rec, &resp)

	if resp.Name != "pipeline-ci" {
		t.Errorf("name = %q, esperado \"pipeline-ci\"", resp.Name)
	}
	if !strings.HasPrefix(resp.Key, "tm_key_") {
		t.Errorf("key = %q, deveria começar com \"tm_key_\"", resp.Key)
	}
	if resp.Message == "" {
		t.Error("a resposta deveria avisar que a chave não será exibida de novo")
	}
}

// O INSERT precisa gravar o hash da chave devolvida, não a chave.
func TestCreateKeyHandler_GravaHashENaoAChave(t *testing.T) {
	app, script := newTestApp(t)
	script.cols = []string{"id"}
	script.rows = [][]driver.Value{{int64(1)}}

	rec := httptest.NewRecorder()
	app.createKeyHandler(rec, postCreateKey(t, `{"name": "app-mobile"}`))

	var resp CreateKeyResponse
	decodeJSON(t, rec, &resp)

	args := script.lastArgs()
	if len(args) != 2 {
		t.Fatalf("esperava 2 argumentos no INSERT (name, key_hash), veio %d: %v", len(args), args)
	}
	if args[0] != "app-mobile" {
		t.Errorf("primeiro argumento = %v, esperado \"app-mobile\"", args[0])
	}
	if args[1] != hashAPIKey(resp.Key) {
		t.Errorf("segundo argumento = %v, esperado o hash da chave devolvida", args[1])
	}
	if args[1] == resp.Key {
		t.Error("a chave em texto plano foi gravada no banco")
	}
}

func TestCreateKeyHandler_ErroDeBancoRetorna500(t *testing.T) {
	app, script := newTestApp(t)
	script.err = errors.New("unique constraint violada")

	rec := httptest.NewRecorder()
	app.createKeyHandler(rec, postCreateKey(t, `{"name": "duplicada"}`))

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, esperado %d", rec.Code, http.StatusInternalServerError)
	}
	if strings.Contains(rec.Body.String(), "tm_key_") {
		t.Error("a chave gerada vazou na mensagem de erro")
	}
}

// --- Middleware da MASTER_KEY ---

func chamaMiddleware(t *testing.T, app *App, header string) (*httptest.ResponseRecorder, *bool) {
	t.Helper()

	chamado := false
	protegido := app.masterKeyAuthMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		chamado = true
		w.WriteHeader(http.StatusTeapot)
	}))

	req := httptest.NewRequest(http.MethodPost, "/admin/keys", nil)
	if header != "" {
		req.Header.Set("Authorization", header)
	}

	rec := httptest.NewRecorder()
	protegido.ServeHTTP(rec, req)
	return rec, &chamado
}

func TestMasterKeyAuthMiddleware_ChaveCorretaLiberaOHandler(t *testing.T) {
	app, _ := newTestApp(t)

	rec, chamado := chamaMiddleware(t, app, "Bearer "+masterKeyDeTeste)

	if !*chamado {
		t.Fatal("o handler protegido não foi executado com a MASTER_KEY correta")
	}
	if rec.Code != http.StatusTeapot {
		t.Errorf("status = %d, esperado %d (do handler interno)", rec.Code, http.StatusTeapot)
	}
}

func TestMasterKeyAuthMiddleware_SemHeaderRetorna403(t *testing.T) {
	app, _ := newTestApp(t)

	rec, chamado := chamaMiddleware(t, app, "")

	if *chamado {
		t.Fatal("o handler protegido foi executado sem Authorization")
	}
	if rec.Code != http.StatusForbidden {
		t.Errorf("status = %d, esperado %d", rec.Code, http.StatusForbidden)
	}
}

func TestMasterKeyAuthMiddleware_ChaveErradaRetorna403(t *testing.T) {
	app, _ := newTestApp(t)

	rec, chamado := chamaMiddleware(t, app, "Bearer chave-errada")

	if *chamado {
		t.Fatal("o handler protegido foi executado com MASTER_KEY inválida")
	}
	if rec.Code != http.StatusForbidden {
		t.Errorf("status = %d, esperado %d", rec.Code, http.StatusForbidden)
	}
}

// Uma chave de API comum (válida no /validate) não pode abrir o /admin.
func TestMasterKeyAuthMiddleware_ChaveDeApiComumNaoAbreAdmin(t *testing.T) {
	app, _ := newTestApp(t)

	chaveComum, err := generateAPIKey()
	if err != nil {
		t.Fatalf("generateAPIKey: %v", err)
	}

	_, chamado := chamaMiddleware(t, app, "Bearer "+chaveComum)
	if *chamado {
		t.Fatal("uma chave de API comum conseguiu acessar o endpoint de admin")
	}
}
