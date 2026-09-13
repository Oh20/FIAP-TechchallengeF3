package main

import (
	"crypto/sha256"
	"encoding/hex"
	"regexp"
	"strings"
	"testing"
)

// hashAPIKey precisa ser determinístico: o /validate recalcula o hash da chave
// recebida e compara com o que está gravado no banco. Se o hash variar, nenhuma
// chave jamais valida.
func TestHashAPIKey_EhDeterministico(t *testing.T) {
	const chave = "tm_key_abc123"

	primeiro := hashAPIKey(chave)
	segundo := hashAPIKey(chave)

	if primeiro != segundo {
		t.Fatalf("hashAPIKey não é determinístico: %q != %q", primeiro, segundo)
	}
}

// O schema do banco declara key_hash VARCHAR(64): o hash precisa caber lá.
func TestHashAPIKey_FormatoHex64(t *testing.T) {
	hash := hashAPIKey("qualquer-coisa")

	if len(hash) != 64 {
		t.Errorf("hash deveria ter 64 caracteres (VARCHAR(64) no init.sql), tem %d", len(hash))
	}

	if !regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(hash) {
		t.Errorf("hash deveria ser hexadecimal minúsculo, veio %q", hash)
	}
}

// Confere contra a implementação de referência de SHA-256.
func TestHashAPIKey_ConfereComSHA256(t *testing.T) {
	const chave = "tm_key_referencia"

	esperado := sha256.Sum256([]byte(chave))
	if got, want := hashAPIKey(chave), hex.EncodeToString(esperado[:]); got != want {
		t.Errorf("hashAPIKey(%q) = %q, esperado %q", chave, got, want)
	}
}

func TestHashAPIKey_ChavesDiferentesGeramHashesDiferentes(t *testing.T) {
	if hashAPIKey("chave-a") == hashAPIKey("chave-b") {
		t.Error("chaves diferentes geraram o mesmo hash")
	}
}

func TestHashAPIKey_AceitaStringVazia(t *testing.T) {
	// Não deve entrar em pânico — o handler chama hashAPIKey antes de qualquer
	// validação mais forte em alguns caminhos.
	if len(hashAPIKey("")) != 64 {
		t.Error("hashAPIKey(\"\") deveria devolver 64 caracteres")
	}
}

func TestGenerateAPIKey_TemPrefixoETamanhoEsperados(t *testing.T) {
	chave, err := generateAPIKey()
	if err != nil {
		t.Fatalf("generateAPIKey devolveu erro: %v", err)
	}

	if !strings.HasPrefix(chave, "tm_key_") {
		t.Errorf("chave deveria começar com \"tm_key_\", veio %q", chave)
	}

	// "tm_key_" (7) + 32 bytes em hex (64) = 71.
	if len(chave) != 71 {
		t.Errorf("chave deveria ter 71 caracteres, tem %d (%q)", len(chave), chave)
	}

	corpo := strings.TrimPrefix(chave, "tm_key_")
	if _, err := hex.DecodeString(corpo); err != nil {
		t.Errorf("corpo da chave não é hexadecimal válido: %v", err)
	}
}

// 256 bits de entropia: colisão em 200 chamadas é impossível na prática.
// Se este teste falhar, o gerador está quebrado (ex.: seed fixa).
func TestGenerateAPIKey_NaoRepeteChaves(t *testing.T) {
	vistas := make(map[string]struct{}, 200)

	for i := 0; i < 200; i++ {
		chave, err := generateAPIKey()
		if err != nil {
			t.Fatalf("generateAPIKey devolveu erro na iteração %d: %v", i, err)
		}
		if _, dup := vistas[chave]; dup {
			t.Fatalf("generateAPIKey repetiu a chave %q na iteração %d", chave, i)
		}
		vistas[chave] = struct{}{}
	}
}
