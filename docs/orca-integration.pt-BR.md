# Integração de terminais externos do Orca

Este fork mantém o Orca como autoridade dos terminais e usa o Open Maestri como
plano de controle visual. Apenas terminais criados pelo fluxo do Agentic OS são
descobertos por seus metadados de worker e recebem nós vivos no canvas. Shells
interativos não relacionados do Orca são ignorados. O bridge não altera o
`workspace.json` compatível com o Maestri.

## O que já funciona

- saída incremental com cursor e limite de 500 linhas no nó;
- estado, ambiente, worktree, branch, papel e modelo visíveis;
- envio em fila após `tui-idle` ou interrupção explícita;
- reconciliação de handles após restart do Orca;
- backoff independente quando uma VPS está indisponível;
- notas conectadas enviadas diretamente como snapshots delimitados, deduplicados
  por hash e limitados a 24.000 caracteres;
- árvore coordenador → subagentes reconstruída a partir do Orca orchestration e
  dos eventos `worker_*` do Agentic OS;
- sidecar por workspace, com gravação atômica, sem mudar o schema v2 original.

O ciclo de vida dos nós externos é somente leitura no Open Maestri: eles não
possuem ação local de exclusão porque o Orca é a autoridade. O cleanup do fluxo
é refletido pelo ciclo de reconciliação, em vez de o proxy ser ocultado localmente
e recriado logo depois. Terminais criados diretamente no Open Maestri mantêm
seus controles normais de fechar e excluir.

## Fluxo Agentic OS

Habilite a visualização nos dois contratos SDD:

```yaml
orchestration:
  subagents:
    required: true
    visualize_in_orca: true
```

Dentro do coordenador criado pelo `agentic-run.sh`, um agente pode abrir um
subagente visual com:

```bash
~/.agentic-os/scripts/agentic-subagent.sh spawn \
  --task-id minha-task \
  --worker-id backend \
  --role "Engenheiro backend" \
  --prompt "Revise e implemente o contrato HTTP."
```

O helper cria/reutiliza um Run do Orca, registra a task filha, abre outro
terminal na mesma worktree e o coloca sob supervisão. O Open Maestri desenha os
nós e as conexões assim que observa esses estados.

## Notas e entrega de contexto

Uma alteração em nota conectada usa **fila** por padrão: o conteúdo só entra
quando o terminal informa `tui-idle`. O botão **Interrupt and send** existe para
o usuário decidir interromper a rodada atual. O snapshot é enviado diretamente
pelo Orca; portanto, o agente externo não precisa possuir `MAESTRI_SOCKET` nem
executar `omaestri note read`.

## Local e VPS

O runtime local é automático. Depois de cadastrar um Orca Server remoto, ele
aparece em `orca environment list --json` e passa a ser observado pelo registro.
Cada nó mostra o nome do ambiente. Uma falha remota entra em backoff exponencial
sem congelar os terminais locais.

## Teste manual final

1. Abra no Open Maestri um workspace apontando para a mesma worktree ativa no
   Orca.
2. Confirme o nó espelhado e sua saída.
3. Teste **Queue message** e, deliberadamente, **Interrupt and send**.
4. Conecte uma nota ao nó, altere e salve a nota.
5. Inicie uma spec com `visualize_in_orca: true` e confira a árvore.
6. Reinicie o Orca e valide que o nó recupera o novo handle.
