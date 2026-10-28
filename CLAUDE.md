# Esteira — guia para agentes de IA

App nativo para macOS 14+ que mostra, na barra de menus, o status do GitHub Actions de branches escolhidos (ex.: `master` e `homolog` de vários repos). Tem um ícone que resume tudo (verde / laranja girando / vermelho), um menu com uma linha por branch e notificações quando uma execução termina. Fala com o GitHub **só pelo `gh` CLI** (sem token próprio). Swift 6 (modo de linguagem 5) + AppKit, **sem dependências externas**, compilado só com as Command Line Tools. Projeto irmão do [Notinhas](https://github.com/victorreinor/notinhas): mesmo esquema de build, release e instalador.

Detalhes de arquitetura, regras de status e de notificação: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Comandos

```sh
swift build                       # build debug
./scripts/test.sh                 # testes (Swift Testing) do EsteiraCore — use em vez de `swift test`
./scripts/build-app.sh            # build.noindex/Esteira.app — release, universal (arm64 + x86_64), assinatura ad-hoc
./scripts/install-dev.sh          # compila, substitui /Applications/Esteira.app e abre
./scripts/screenshots.sh          # regenera docs/images (imagens do README) fora da tela, com repos fictícios
./scripts/release.sh              # testa, builda, cria a tag da próxima versão e a GitHub Release com Esteira.zip
./scripts/next-version.sh         # só mostra qual seria a próxima versão

# Diagnóstico: pergunta ao gh uma vez, imprime o menu em texto (+ status geral e permissão de notificação) e sai.
ESTEIRA_PRINT_MENU=1 build.noindex/Esteira.app/Contents/MacOS/Esteira
```

Com só as Command Line Tools, o `swift test` puro falha de forma intermitente com `plugin for module 'TestingMacros' not found`. O `scripts/test.sh` passa o `-plugin-path` certo. O aviso `ld: warning: search path '.../Developer/Library/Frameworks' not found` é inofensivo.

## Mapa do código

| Arquivo | Responsabilidade |
| --- | --- |
| `Sources/EsteiraCore/WorkflowRun.swift` | Uma execução como o `gh run list --json` devolve (`ghFields`), `RunState` (queued/running/waiting/passed/failed/cancelled/neutral) e `RunKey` (id + tentativa). |
| `Sources/EsteiraCore/BranchStatus.swift` | Resume as execuções de um branch numa `headline` (+ `previous` enquanto roda) e o `Overall` do ícone. Puro e testado. |
| `Sources/EsteiraCore/CompletionTracker.swift` | Decide quais execuções terminaram desde a última olhada (cada uma avisada uma vez; a primeira olhada não avisa nada). |
| `Sources/EsteiraCore/Notice.swift` | Texto da notificação: passou / voltou a passar / quebrou; nil para cancelado e pulado. |
| `Sources/EsteiraCore/Config.swift` | `config.json` (repos, branches, workflow opcional), `Target` (um repo + branch, com os argumentos do `gh`) e `RepoInput` (aceita URL, `dono/nome`, endereço SSH). |
| `Sources/EsteiraCore/Format.swift` | Textos curtos em pt-BR: "há 12 min", "6 min", "passou em 6 min · há 12 min", truncar commit. |
| `Sources/EsteiraCore/Polling.swift` | Intervalo entre consultas (30 s / 15 s rodando, estica com muitos branches) e tradução dos erros do `gh` para frases curtas. |
| `Sources/Esteira/GitHubCLI.swift` | Acha o `gh` (Homebrew, Nix, shell de login), roda com PATH completo e timeout de 30 s, devolve stdout ou erro amigável. |
| `Sources/Esteira/Monitor.swift` | Estado do app: config (relida quando o arquivo muda), status de cada branch, timer de consulta, acordar do sleep, `CompletionTracker` → `onNotice`. |
| `Sources/Esteira/StatusController.swift` | `NSStatusItem` + `NSMenu`: ícone (girando via timer), reconstrói o menu ao abrir, ações (abrir execução, adicionar/remover repo, editar config, toggles). |
| `Sources/Esteira/MenuBuilder.swift` | Monta os `NSMenuItem` a partir de um `MenuModel` (também usado pelo snapshot e pelo `ESTEIRA_PRINT_MENU`). |
| `Sources/Esteira/StatusIcons.swift` | SF Symbols coloridos do ícone da barra e das linhas do menu; quadros da rotação. |
| `Sources/Esteira/Notifier.swift` | `UNUserNotificationCenter`: pede permissão, posta, abre a execução no clique, informa se as notificações estão desligadas. |
| `Sources/Esteira/AddRepoDialog.swift` | `NSAlert` com 3 campos (repo, branches, workflow); o `StatusController` valida com o `gh` e reabre com o erro. |
| `Sources/Esteira/LoginItem.swift` | Abrir ao iniciar o Mac (`SMAppService`), ligado uma vez na primeira execução. |
| `Sources/Esteira/Snapshot.swift` | Ferramenta de dev: desenha as imagens do README a partir dos itens reais do `MenuBuilder`. |
| `Sources/Esteira/AppDelegate.swift` | Liga tudo; modos `ESTEIRA_SNAPSHOT_DIR` e `ESTEIRA_PRINT_MENU`. |
| `install.sh` | Instalador de um comando para usuários finais (baixa a última Release e avisa se falta o `gh`). |

## Decisões de produto — não mudar sem perguntar ao dono

- Vive **só na barra de menus**: sem Dock, sem ⌘Tab, sem janela (`LSUIElement`). Não é um widget do WidgetKit de propósito: widgets não podem rodar o `gh` e o macOS limita quantas vezes eles atualizam; um status de CI "rodando" ficaria velho.
- Fala com o GitHub **só pelo `gh`**. Nada de pedir ou guardar token, nem chamar a API direto com `URLSession`.
- Ícone: verde = tudo passou; laranja girando = algo roda; vermelho girando = algo roda e outro branch está quebrado; vermelho X = algo quebrou. "Rodando" ganha de "quebrado" no formato (gira), e a cor mostra se há algo quebrado.
- Notificações: quebrou (com som), voltou a passar e passou (sem som; desligável em "Avisar também quando passar"). Cancelado e pulado não notificam. **Nunca** notificar resultados que já existiam quando o app abriu ou quando o repo foi adicionado.
- Clicar num branch ou numa notificação abre a execução no GitHub.
- Textos da interface em português (pt-BR); código, comentários e logs em inglês.
- Sem CI/CD (nada de GitHub Actions): testes e releases rodam localmente, com `scripts/test.sh` e `scripts/release.sh`.
- Não mudar o bundle id `dev.victorreinor.esteira`, a pasta `~/Library/Application Support/Esteira` nem o formato do `config.json` de forma incompatível (campos novos precisam de default no `init(from:)`). Não mudar o nome do asset `Esteira.zip` (o `install.sh` baixa `releases/latest/download/Esteira.zip`).
- As imagens do README usam repos **fictícios** (`acme/...`). Não coloque nomes de repositórios reais de ninguém nelas.

## Armadilhas

- **Nunca rode o binário de dev "puro"** (`.build/.../Esteira` sem `ESTEIRA_PRINT_MENU` ou `ESTEIRA_SNAPSHOT_DIR`): ele abre uma segunda cópia do app, com um segundo ícone na barra. Encadeie com o build (`swift build && ESTEIRA_PRINT_MENU=1 …`) para não rodar um binário antigo, sem o modo, quando a compilação falhar. Se acontecer: `pkill -f '\.build/.*/Esteira$'`.
- **O `log` do zsh é um comando interno do shell.** Para ler os logs do sistema, use `/usr/bin/log show --last 10m --predicate 'eventMessage CONTAINS "Esteira:"'`. Permissão de notificação: `--predicate 'process == "usernoted" AND eventMessage CONTAINS[c] "esteira"'`.
- **App aberto pelo Finder ou no login tem PATH mínimo.** `GitHubCLI` procura o `gh` em caminhos conhecidos e passa um PATH completo para ele (o `gh` chama `/usr/bin/security` para ler o token do Chaveiro). Não troque por `Process` com `/usr/bin/env gh`.
- `UNUserNotificationCenter.current()` derruba o processo sem bundle (binário de `.build`). Tudo que toca em notificação é protegido por `Bundle.main.bundleIdentifier != nil`. Com assinatura ad-hoc as notificações funcionam; se o usuário negar, o menu mostra "Ativar notificações…".
- **`NSMenu` não renderiza fora da tela.** O `Snapshot` desenha o menu à mão a partir dos `NSMenuItem` do `MenuBuilder` (título atribuído, `subtitle`, imagem, `state`, atalho, submenu). Se criar um tipo novo de item, ensine o `Snapshot.drawRow` a desenhá-lo e o `MenuBuilder.text` a imprimi-lo.
- Timers (consulta e rotação do ícone) entram no `RunLoop.main` em `.common`. Com `Timer.scheduledTimer` eles param enquanto o menu está aberto.
- `NSMenuItem.subtitle` só existe no macOS 14.4+. Abaixo disso, o commit vai numa segunda linha do `attributedTitle`. Não use cor explícita no título da linha (o destaque azul do menu não inverteria a cor).
- No macOS 26+, o item "Sair" (`terminate:`) ganha um ícone automático do sistema. É esperado.
- `CompletionTracker`: a primeira olhada em cada branch só memoriza (`primed`). Ao remover um branch da config, chame `forget` para que, se ele voltar, o histórico não vire notificação. A chave é id + tentativa, porque um "Re-run" reaproveita o id.
- Limite do GitHub: 5000 requisições/hora por login, compartilhadas com o resto do uso do `gh`. Mudou a frequência? Ajuste `Polling.interval` e o teste dele, mantendo o teto de ~2000/h.
- `config.json` editado à mão com JSON inválido: o app mantém a última lista boa e mostra o erro no rodapé do menu. A releitura é por data de modificação, a cada consulta.
- Swift 6 em modo de linguagem 5: `AppDelegate`, `Monitor` e `StatusController` são `@MainActor`; o `main.swift` cria o delegate com `MainActor.assumeIsolated`.
- A saída do build fica em `build.noindex/`, não `build/`: o sufixo `.noindex` impede o Spotlight de mostrar um segundo "Esteira" ao lado do de `/Applications`.

## Verificando uma mudança

Este ambiente não tem Xcode, e o terminal não tem permissão de Gravação de Tela nem de Acessibilidade: não dá para ver a barra de menus nem clicar no menu.

1. `./scripts/test.sh` para a lógica.
2. `./scripts/build-app.sh && ESTEIRA_PRINT_MENU=1 build.noindex/Esteira.app/Contents/MacOS/Esteira` para conferir o menu com os dados reais do `gh`.
3. `./scripts/screenshots.sh` e **olhe** os PNGs em `docs/images/` para qualquer mudança visual.
4. `./scripts/install-dev.sh` e confira com `pgrep -lx Esteira` (uma cópia só!), `sfltool dumpbtm | grep -A6 -i esteira` (login item) e os logs (`/usr/bin/log`, acima).
5. O que exige mãos humanas: ver o ícone girando, abrir o menu, clicar num branch, adicionar e remover repo pelo diálogo, receber e clicar numa notificação. Peça ao usuário para testar e diga isso explicitamente.
