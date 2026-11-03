# Pipelight para Linux

Port nativo do Pipelight para GTK 3 e AppIndicator, com interface em português. Usa o login existente do GitHub CLI (`gh`), sem pedir ou armazenar tokens. Implementado em Python 3.10 ou superior, com bibliotecas do sistema e sem pacotes do PyPI.

## Instalar no Ubuntu / Debian

Na cópia deste repositório ou no pacote `Pipelight-linux.tar.gz` extraído:

```sh
sudo apt install python3-gi gir1.2-gtk-3.0 gir1.2-notify-0.7 gir1.2-ayatanaappindicator3-0.1 gh
gh auth login
./scripts/install-linux.sh --start
```

Se as dependências já estiverem presentes, basta o último comando. No Ubuntu, quando só falta o typelib do AppIndicator, o instalador baixa esse pequeno pacote pelos índices confiáveis do APT e extrai os metadados na sua conta, sem `sudo`. Não altera o Python do sistema.

O aplicativo fica em `~/.local/share/pipelight`, com o comando `~/.local/bin/pipelight` e um atalho **Pipelight** no menu de aplicativos. Uma segunda abertura mantém uma única instância. Reexecute o instalador para atualizar e reinicie pelo menu; suas configurações são preservadas.

Clique no ícone perto do relógio e escolha **Adicionar repositório…**. Informe `dono/nome` ou uma URL, branches separados por vírgula e, opcionalmente, um workflow. Branch vazio usa o padrão do repositório. **Abrir ao iniciar o Linux** habilita o início automático, desligado por padrão nesta versão.

O GNOME precisa de uma extensão de AppIndicator/StatusNotifier. O Ubuntu Desktop normalmente já a inclui. Outros ambientes precisam de uma bandeja compatível (por exemplo, KDE ou Xfce). O port foi verificado no Ubuntu 24.04, GNOME/Wayland; outras distribuições não foram validadas.

## Recursos

- Status por repositório e branch, com filtro por nome, arquivo ou ID de workflow.
- Ícone verde, vermelho ou animado enquanto roda; clicar no branch abre sua execução no GitHub.
- Ícones seguem o visual do Mac, com um único símbolo em destaque: setas animadas durante execução, X vermelho em falha, check verde em sucesso e check azul para PR pronto. O status da fila ocupa o ícone inteiro, sem bolinha sobreposta. Execuções em andamento têm prioridade, inclusive quando só há PRs na fila; se houver uma falha simultânea, as setas ficam vermelhas.
- Notificações de falha, recuperação e sucesso; sucesso comum pode ser desligado. A primeira consulta não anuncia histórico.
- Fila de PRs por link, pelos seus PRs ou pelos pedidos de revisão. **Atualizar sugestões** busca novamente a lista.
- Aviso quando o branch de destino libera e quando o CI do PR termina; o símbolo de cada PR mostra seu estado. PRs fechados/mergeados saem da fila.
- Consultas a cada 15 segundos durante execução e 30 segundos em repouso. A frequência diminui com muitos alvos. Erros de rede preservam o último estado, acompanhado do erro.
- Configuração recarregada automaticamente, início automático opcional e atualização após suspensão.

O sinal “pronto para mergear” indica CI aprovado e branch de destino livre, seguindo a regra do aplicativo original. Não verifica todas as políticas de merge (aprovações, conflitos ou proteções). O aplicativo apenas monitora e abre links; o merge é feito no GitHub.

O som, a apresentação e o clique das notificações dependem das preferências do ambiente gráfico. Não Perturbe pode ocultar os avisos.

## Configuração e diagnóstico

Os arquivos ficam em `~/.config/pipelight/` (ou `$XDG_CONFIG_HOME/pipelight`):

- `config.json`: mesmo formato de repositórios do app macOS; pode ser copiado entre os sistemas.
- `queue.json`: fila local do Linux. Não é intercambiável com a fila serializada em Swift.
- `settings.json`: preferência `notifyPassed`.

```json
{
  "repos": [
    {"repo": "acme/api", "branches": ["main", "homolog"], "workflow": "CI"}
  ]
}
```

O app mantém a última configuração válida se houver um erro ao editar JSON e mostra a mensagem no menu. Corrija arquivos inválidos antes de alterá-los pelo aplicativo. Ele não apaga uma fila ilegível.

```sh
~/.local/bin/pipelight --check             # dependências e autenticação
~/.local/bin/pipelight --print-menu        # consulta uma vez, sem gravar nem notificar
~/.local/bin/pipelight --demo              # demonstração offline com dados fictícios
~/.local/bin/pipelight --data-dir /tmp/pl --print-menu
```

O instalador com `--start` registra a saída em `~/.local/state/pipelight/app.log`. Para depurar uma execução iniciada manualmente, feche a instância existente e rode `~/.local/bin/pipelight --verbose` num terminal.

Para desinstalar, feche **Sair do Pipelight** e execute:

```sh
rm -rf ~/.local/share/pipelight
rm -f ~/.local/bin/pipelight
rm -f ~/.local/share/applications/dev.victorreinor.pipelight.desktop
rm -f ~/.config/autostart/dev.victorreinor.pipelight.desktop
```

Os dados em `~/.config/pipelight` são preservados. Ajuste os caminhos se você usa diretórios XDG personalizados.

## Desenvolvimento

```sh
./scripts/test-linux.sh
PYTHONPATH=linux /usr/bin/python3 -m pipelight --demo
./scripts/build-linux.sh                  # build.noindex/Pipelight-linux.tar.gz
```

O teste gráfico usa Xvfb e uma sessão D-Bus isolada:

```sh
env -u WAYLAND_DISPLAY GDK_BACKEND=x11 GIO_USE_VFS=local NO_AT_BRIDGE=1 \
  PYTHONPATH=linux dbus-run-session -- xvfb-run -a -s '-screen 0 1440x1200x24' \
  /usr/bin/python3 linux/tests/smoke_gtk.py
```

Se o typelib foi instalado na sua conta, acrescente `GI_TYPELIB_PATH="$HOME/.local/share/pipelight/vendor"` entre `NO_AT_BRIDGE=1` e `PYTHONPATH=linux`. As imagens de verificação são salvas em `build.noindex/linux-smoke.png` (diálogo) e `build.noindex/linux-menu-smoke.png` (menu).

`pipelight/core.py` contém as regras portadas de `Sources/PipelightCore`; `monitor.py` coordena as consultas; `github.py` executa apenas comandos de leitura do `gh`; `storage.py` grava JSON atomicamente; `app.py` mantém o GTK na thread principal. As operações do monitor são serializadas em um worker e cada consulta usa até quatro chamadas concorrentes. A UI recebe cópias do estado.

A consulta de runs usa `gh api` para conservar `run_attempt` inclusive no GitHub CLI 2.45 do Ubuntu, cujo `gh run list --json` ainda não expõe `attempt`. O código e o instalador do macOS continuam disponíveis separadamente. Não há publicação automática nem workflows de CI.
