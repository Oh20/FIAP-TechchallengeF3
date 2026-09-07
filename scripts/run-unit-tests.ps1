<#
.SYNOPSIS
    Roda localmente a mesma suíte de testes unitários que o Jenkins executa.

.DESCRIPTION
    Usa os mesmos scripts (scripts/ci/*.sh) e as mesmas imagens Docker do
    pipeline_unit_tests.jenkinsfile, então o resultado local é idêntico ao do CI.
    Não é preciso ter Go nem Python instalados — só o Docker Desktop rodando.

    Os relatórios vão para test-reports/ na raiz do repositório.

.PARAMETER Servico
    Roda só um serviço. Padrão: todos.

.PARAMETER SemRace
    Desliga o detector de corrida (-race) nos testes Go. Fica mais rápido.

.EXAMPLE
    # A partir da raiz do repositorio da aplicacao (pasta app/):
    ./scripts/run-unit-tests.ps1
    ./scripts/run-unit-tests.ps1 -Servico flag-service
    ./scripts/run-unit-tests.ps1 -SemRace
#>
[CmdletBinding()]
param(
    [ValidateSet('todos', 'auth-service', 'evaluation-service', 'flag-service',
                 'targeting-service', 'analytics-service')]
    [string]$Servico = 'todos',

    [switch]$SemRace
)

$ErrorActionPreference = 'Stop'

# Raiz do repositório da aplicação: um nível acima de scripts/.
# (os microsserviços ficam em <raiz>/app/<servico>)
$RaizRepo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Relatorios = Join-Path $RaizRepo 'test-reports'

$GoImage = 'golang:1.25'
$PyImage = 'python:3.13-slim'

$Catalogo = @(
    @{ Nome = 'auth-service';       Linguagem = 'go' },
    @{ Nome = 'evaluation-service'; Linguagem = 'go' },
    @{ Nome = 'flag-service';       Linguagem = 'python' },
    @{ Nome = 'targeting-service';  Linguagem = 'python' },
    @{ Nome = 'analytics-service';  Linguagem = 'python' }
)

# --- Validação do ambiente -------------------------------------------------

Write-Host '=== Validando o ambiente ===' -ForegroundColor Cyan

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker não encontrado no PATH. Instale o Docker Desktop.'
}

docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'O daemon do Docker não está respondendo. Abra o Docker Desktop e tente de novo.'
}

Write-Host ("  Docker : " + (docker --version))
Write-Host ("  Repo   : " + $RaizRepo)

if (Test-Path $Relatorios) { Remove-Item $Relatorios -Recurse -Force }
New-Item -ItemType Directory -Path $Relatorios | Out-Null

# --- Execução ---------------------------------------------------------------

$aRodar = if ($Servico -eq 'todos') { $Catalogo } else { $Catalogo | Where-Object { $_.Nome -eq $Servico } }
$falhas = @()

foreach ($svc in $aRodar) {
    $nome = $svc.Nome
    Write-Host ''
    Write-Host "=== $nome ($($svc.Linguagem)) ===" -ForegroundColor Cyan

    $imagem = if ($svc.Linguagem -eq 'go') { $GoImage } else { $PyImage }
    $script = if ($svc.Linguagem -eq 'go') { 'test-go.sh' } else { 'test-python.sh' }

    $args = @(
        'run', '--rm',
        '-v', "${RaizRepo}:/workspace",
        '-w', "/workspace/app/$nome",
        '-e', 'REPORTS_DIR=/workspace/test-reports'
    )

    if ($svc.Linguagem -eq 'go') {
        $args += @('-e', "GO_RACE=$(if ($SemRace) { '0' } else { '1' })")
    }

    $args += @($imagem, 'sh', "/workspace/scripts/ci/$script", $nome)

    & docker @args
    if ($LASTEXITCODE -ne 0) {
        $falhas += $nome
        Write-Host "  FALHOU: $nome" -ForegroundColor Red
    }
}

# --- Resumo -----------------------------------------------------------------

Write-Host ''
Write-Host '=== Cobertura ===' -ForegroundColor Cyan

foreach ($svc in $aRodar) {
    $arquivo = Join-Path $Relatorios ("cobertura-" + $svc.Nome + ".txt")
    $valor = if (Test-Path $arquivo) { (Get-Content $arquivo -Raw).Trim() } else { 'n/d' }
    Write-Host ("  {0,-22} {1,6} %" -f $svc.Nome, $valor)
}

Write-Host ''
if ($falhas.Count -gt 0) {
    Write-Host ("Serviços com falha: " + ($falhas -join ', ')) -ForegroundColor Red
    Write-Host "Relatórios em: $Relatorios"
    exit 1
}

Write-Host 'Todos os testes unitários passaram.' -ForegroundColor Green
Write-Host "Relatórios em: $Relatorios"
