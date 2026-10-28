# Arquitetura

```
                ┌──────────────────────────────── Pipelight (app, AppKit) ─────────────────────────────────┐
 timer 15–30 s ─▶│ Monitor ── para cada Target ──▶ GitHubCLI.run(["run","list",…]) ──▶ gh ──▶ GitHub API │
 acordar Mac   ─▶│   │ ▲                                        │ [WorkflowRun]                               │
 abrir o menu  ─▶│   │ └── config.json (relido se mudou)        ▼                                             │
                │   │                             PipelightCore: BranchStatus · Overall · CompletionTracker    │
                │   │ onChange                                  │ Completion → Notice                         │
                │   ▼                                           ▼                                            │
                │ StatusController ── MenuBuilder ──▶ NSMenu   Notifier ──▶ Central de Notificações         │
                │   └─ ícone (StatusIcons, gira enquanto roda)                                               │
                └────────────────────────────────────────────────────────────────────────────────────────────┘
```

`PipelightCore` não importa AppKit: modelos, regras de status, de notificação, config e textos são puros e testados. `Pipelight` é a camada AppKit, e só ela roda processos e mexe em UI.

## Ciclo de uma consulta (`Monitor.refresh`)

1. Relê o `config.json` se a data de modificação mudou (sem arquivo, cria um vazio). JSON inválido mantém a lista anterior e põe o erro em `configError`.
2. Para cada `Target` (repo × branch), roda `gh run list --repo R --branch B --limit 5|20 --json <campos> [--workflow W]` em paralelo (`TaskGroup`). Sem workflow, pede 20 execuções para achar a última de cada workflow.
3. Sucesso: guarda `BranchStatus(runs:)` e passa as execuções ao `CompletionTracker`. Erro: mantém o status anterior e guarda a frase do erro (`Polling.explain`).
4. Agenda a próxima: `Polling.interval(targets:running:)`. São 30 s parado e 15 s com algo rodando, e o intervalo estica para não passar de ~2000 requisições por hora.
5. Pedidos de atualização durante uma consulta não são perdidos (`refreshAgain`).

Também atualiza 5 s depois de o Mac acordar e ao abrir o menu, se os dados tiverem mais de 10 s.

## Regras de status (`BranchStatus`)

- Execuções `skipped` são ignoradas.
- Cada workflow conta só com a **sua última** execução, então uma falha antiga que já foi corrigida não aparece.
- `headline` é a primeira execução ativa (fila, rodando, esperando aprovação); se não houver, a primeira que falhou; se não houver, a mais recente.
- `previous`: enquanto a headline roda, a última execução **terminada** do mesmo workflow. É o "antes passou / antes quebrou" do menu.

`Overall` (o ícone): sem repos → `.empty`; algo ativo → `.running(failing:)`; algo quebrado → `.failed`; nenhum dado → `.unknown`; senão `.passed`. Cancelado não deixa vermelho.

| `status` / `conclusion` do GitHub | `RunState` |
| --- | --- |
| `queued`, `requested`, `pending` | `.queued` |
| `in_progress` | `.running` |
| `waiting`, `action_required` | `.waiting` |
| `success` | `.passed` |
| `failure`, `timed_out`, `startup_failure` | `.failed` |
| `cancelled` | `.cancelled` |
| `skipped`, `neutral`, `stale` | `.neutral` |

## Regras de notificação (`CompletionTracker` + `Notice`)

- A primeira consulta de cada branch só memoriza as execuções terminadas: abrir o app ou adicionar um repo não gera notificação.
- Depois disso, toda execução terminada que ainda não foi vista vira uma `Completion`. Isso inclui uma que começou e terminou entre duas consultas e um "Re-run" (mesmo id, `attempt` maior).
- `Notice`: `failed` → "❌ repo · branch quebrou" (com som); `passed` com a anterior do mesmo workflow `failed` → "✅ … voltou a passar"; `passed` → "✅ … passou" (sem som, desligável). Cancelado e pulado: nada.
- O identificador da notificação é `id-attempt`, então a mesma execução nunca aparece duas vezes. Clicar abre `url`.

## O menu

```
[loja-api]                                   ← NSMenuItem.sectionHeader (nome curto do repo)
  ✓ master  passou em 7 min · há 11 min      ← título atribuído (branch em semibold) + imagem do estado
          feat(checkout): parcelamento…      ← subtitle (macOS 14.4+): commit, com o workflow se não há filtro
  ⟳ homolog  rodando há 3 min · antes quebrou
  ────
  Atualizar agora ⌘R · Adicionar repositório… ⌘N · Remover repositório › · Editar config.json…
  ────
  (Ativar notificações… — só quando estão desligadas)
  ✓ Avisar também quando passar · ✓ Abrir ao iniciar o Mac
  ────
  ⚠︎ erro (se houver) · Atualizado às 16:42:10
  Sair do Pipelight ⌘Q
```

O menu é reconstruído em `menuNeedsUpdate` e a cada mudança enquanto está aberto. Clicar num branch abre `headline.url` ou, sem execuções, a aba Actions filtrada pelo branch.

## Persistência

- `~/Library/Application Support/Pipelight/config.json`: a lista de repos (formato no README). Escrito pelo menu (`Monitor.update`) com `.atomic`, ou à mão.
- `UserDefaults` (`dev.victorreinor.pipelight`): `notifyPassed` (padrão `true`) e `loginItemConfigured`.
- Nenhum token: o `gh` guarda o dele no Chaveiro.

## Distribuição

- `scripts/build-app.sh` monta o bundle à mão (sem Xcode): binário universal, `Info.plist`, ícone (`scripts/make-icon.swift` desenha o ícone e o `iconutil` gera o `.icns`) e `codesign --sign -`.
- `scripts/release.sh` (local, sem CI): `scripts/next-version.sh` sobe a última tag (patch, ou `[minor]`/`[major]` no título de um commit), `scripts/test.sh`, `build-app.sh` com `VERSION`, e publica `Pipelight.zip` (feito com `ditto`, que preserva a assinatura) numa GitHub Release `v<versão>`.
- `install.sh` baixa `releases/latest/download/Pipelight.zip`, instala em `/Applications` (ou `~/Applications`), remove a quarentena, abre o app e avisa se falta instalar ou logar o `gh`.
