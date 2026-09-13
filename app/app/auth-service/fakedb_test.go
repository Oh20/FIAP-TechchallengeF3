package main

// fakedb_test.go
//
// Driver database/sql "de mentira", usado APENAS pelos testes unitários.
// Ele permite exercitar os handlers que falam com o Postgres sem subir
// nenhum banco: o teste registra o roteiro (colunas, linhas e erro) que o
// driver deve devolver e depois inspeciona as queries que foram executadas.
//
// Não adiciona nenhuma dependência externa ao go.mod — tudo é stdlib.

import (
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"io"
	"sync"
	"sync/atomic"
)

func init() {
	sql.Register("togglemaster-fake", fakeDriver{})
}

// fakeDB guarda o roteiro de resposta e o histórico de chamadas.
type fakeDB struct {
	mu sync.Mutex

	// Roteiro: o que o driver devolve para qualquer query.
	cols []string
	rows [][]driver.Value
	err  error

	// Histórico capturado para as asserções.
	queries []string
	args    [][]driver.Value
}

func (f *fakeDB) record(query string, args []driver.Value) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.queries = append(f.queries, query)

	copied := make([]driver.Value, len(args))
	copy(copied, args)
	f.args = append(f.args, copied)
}

// lastArgs devolve os argumentos da última query executada.
func (f *fakeDB) lastArgs() []driver.Value {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.args) == 0 {
		return nil
	}
	return f.args[len(f.args)-1]
}

// lastQuery devolve o SQL da última query executada.
func (f *fakeDB) lastQuery() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.queries) == 0 {
		return ""
	}
	return f.queries[len(f.queries)-1]
}

// callCount devolve quantas queries foram executadas.
func (f *fakeDB) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.queries)
}

// --- Registro global de instâncias (uma por teste) ---

var (
	fakeRegistryMu sync.Mutex
	fakeRegistry   = map[string]*fakeDB{}
	fakeSeq        int64
)

// newFakeDB cria um *sql.DB ligado a um roteiro isolado.
func newFakeDB() (*sql.DB, *fakeDB, error) {
	script := &fakeDB{}
	dsn := fmt.Sprintf("fake-%d", atomic.AddInt64(&fakeSeq, 1))

	fakeRegistryMu.Lock()
	fakeRegistry[dsn] = script
	fakeRegistryMu.Unlock()

	db, err := sql.Open("togglemaster-fake", dsn)
	if err != nil {
		return nil, nil, err
	}
	return db, script, nil
}

// --- Implementação do driver ---

type fakeDriver struct{}

func (fakeDriver) Open(dsn string) (driver.Conn, error) {
	fakeRegistryMu.Lock()
	defer fakeRegistryMu.Unlock()

	script, ok := fakeRegistry[dsn]
	if !ok {
		return nil, errors.New("fake driver: dsn não registrado: " + dsn)
	}
	return &fakeConn{script: script}, nil
}

type fakeConn struct{ script *fakeDB }

func (c *fakeConn) Prepare(query string) (driver.Stmt, error) {
	return &fakeStmt{script: c.script, query: query}, nil
}

func (c *fakeConn) Close() error { return nil }

func (c *fakeConn) Begin() (driver.Tx, error) {
	return nil, errors.New("fake driver: transações não são suportadas")
}

type fakeStmt struct {
	script *fakeDB
	query  string
}

func (s *fakeStmt) Close() error { return nil }

// -1 desliga a validação de quantidade de argumentos do database/sql.
func (s *fakeStmt) NumInput() int { return -1 }

func (s *fakeStmt) Exec(args []driver.Value) (driver.Result, error) {
	s.script.record(s.query, args)
	if s.script.err != nil {
		return nil, s.script.err
	}
	return driver.RowsAffected(int64(len(s.script.rows))), nil
}

func (s *fakeStmt) Query(args []driver.Value) (driver.Rows, error) {
	s.script.record(s.query, args)
	if s.script.err != nil {
		return nil, s.script.err
	}
	return &fakeRows{cols: s.script.cols, rows: s.script.rows}, nil
}

type fakeRows struct {
	cols []string
	rows [][]driver.Value
	pos  int
}

func (r *fakeRows) Columns() []string { return r.cols }

func (r *fakeRows) Close() error { return nil }

func (r *fakeRows) Next(dest []driver.Value) error {
	if r.pos >= len(r.rows) {
		// io.EOF é o que faz o QueryRow devolver sql.ErrNoRows.
		return io.EOF
	}
	copy(dest, r.rows[r.pos])
	r.pos++
	return nil
}
