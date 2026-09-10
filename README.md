# Delphi Fiber Runtime

[![CI](https://github.com/ramonruanxc/delphi-fiber-runtime/actions/workflows/ci.yml/badge.svg)](https://github.com/ramonruanxc/delphi-fiber-runtime/actions/workflows/ci.yml)

Runtime Pascal em desenvolvimento, inspirado em virtual threads e nos projetos
[delphi-concurrent-pool](https://github.com/ramonruanxc/delphi-concurrent-pool) e
[delphi-service-host](https://github.com/ramonruanxc/delphi-service-host).

**O projeto tem dois experimentos independentes: agendamento a 1 kHz e fibers.**
O primeiro implementa cadência fixa, temporizadores canceláveis e medição. O
segundo suspende e retoma tarefas com pilhas próprias em uma mesma thread, com
adaptação explícita do runtime FPC. Canais, esperas integradas e ciclo de vida de
serviços são etapas posteriores do [projeto aprovado](docs/superpowers/specs/2026-09-10-delphi-fiber-runtime-design.md).

## O que já pode ser exercitado

- Deadlines monotônicos: `epoch + n * period`, sem acumular o tempo do callback.
- Uma execução ativa por agendamento; ciclos perdidos são descartados e contados.
- Windows: QPC e waitable timer; Linux: timerfd/eventfd; macOS: Mach clock/kqueue.
- Espera nativa até o deadline, sem loop periódico de `Sleep(1)` no agendador.
- CSV com deadline, início e fim; relatórios com percentis e ciclos descartados.
- CI multiplataforma, testes negativos com falha exata e releases por tag.
- Fibers experimentais: chamadas aninhadas, cancelamento cooperativo, contenção
  de exceções e um campo explícito para dados locais de cada tarefa.

`Yield` devolve explicitamente o controle ao executor. Ele pode então retomar
outra tarefa. Código bloqueante arbitrário ainda bloqueia a thread; a integração
entre fibers, temporizadores e canais pertence à etapa seguinte.

## Executar

Instale Free Pascal 3.2.2 e Python 3.12. No Linux, instale as unidades FCL e
`build-essential`; no macOS, FPC pelo Homebrew e as ferramentas de compilação
da Apple. O experimento Unix compila um helper C/assembly estático. Os comandos são iguais no
PowerShell e em shells Unix:

```text
python scripts/check.py
python scripts/package.py
```

Execute esses scripts a partir de um clone Git. O primeiro comando compila,
executa os testes e mede três cenários periódicos e um de alternância de fibers. Os dados
ficam em `build/check/`; o segundo cria os pacotes em `dist/` e compila um
consumidor extraído em um caminho com espaços. O empacotamento usa arquivos
rastreados pelo Git; execute a partir de um clone do repositório.

Para registrar CPU, memória e threads dos cenários periódicos por amostragem, instale opcionalmente
`python -m pip install psutil==7.2.2`. O observador externo pode perturbar os
tempos; os relatórios identificam sua presença e limitações.

O executável `build/check/demo/PeriodicDemo` (`.exe` no Windows) aceita:

```text
PeriodicDemo --cycles 10000 --period-us 1000 --work-us 100
```

`--work-us` simula trabalho de CPU. Os registros são pré-alocados e impressos
somente após a medição. Por padrão, `--work-us` é zero.

## Como interpretar 1 ms

1 ms é o **período planejado**. Sistemas operacionais de uso geral podem iniciar
a execução com atraso. O relatório mede esse atraso e também inclui todos os
ciclos descartados; a média dos callbacks executados não certifica a cadência.

Sem um perfil explícito, o resultado é `descriptive`. Para testar uma tolerância
definida pelo seu cenário, forneça ambos os limites (este é apenas um exemplo):

```text
python scripts/report.py build/check/idle.csv --max-lateness-us 100 --max-violation-fraction 0.01
```

Esse comando avalia atraso de até 100 us em 99% dos ciclos planejados, contando
descartes como violações, e retorna `threshold_assessment`. O resultado continua
descritivo: esses dois limites não certificam o ambiente. Uma qualificação real
exige também hardware, duração, carga e configuração de energia acordados.

## Experimento de fibers

`build/check/context-demo/ContextDemo` (`.exe` no Windows) alterna 16 tarefas na
mesma thread, com 1.000 suspensões por tarefa. O JSON registra conclusões,
suspensões, chamadas de retomada e tempo total. A média inclui o trabalho mínimo
do demo; não é uma certificação de latência nem um benchmark isolado da instrução
de troca de contexto. A criação das pilhas ocorre antes da janela de medição.

As tarefas ficam na thread de origem. `Cancel` apenas solicita cancelamento;
retomar uma tarefa suspensa permite que ela execute sua limpeza. A biblioteca
rejeita a destruição de pilhas ainda suspensas. `threadvar` continua compartilhado
entre tarefas da mesma thread; `LocalValue` é o campo explícito por tarefa.

Não suspenda dentro de tratadores de exceção, durante desenrolamento da pilha ou
segurando locks nativos. O detector de exceção ativa não identifica todos os
casos de desenrolamento. As restrições e a API completa estão no
[contrato de contextos](docs/context-contract.md).

## Portabilidade e próximos passos

A API separa política de agendamento e implementação do sistema operacional.
Compatibilidade universal não é presumida: cada combinação de compilador,
versão, sistema e CPU precisa de evidência própria na [matriz de suporte](docs/support-matrix.md).
Uma execução com FPC não valida Delphi.

O adaptador de contexto é intencionalmente limitado ao FPC 3.2.2 e aos modos de
exceção testados. Ampliar versões exige validar o runtime de cada compilador;
essa limitação não cria uma dependência de fibers nas unidades periódicas.
No Unix, usa Boost.Context 1.85.0 com fontes mínimas e licença incluídas. No
Windows, usa fibers nativas com preservação de estado de ponto flutuante.
Programas Unix devem incluir `cthreads` primeiro no `uses`; o runtime recusa a
configuração padrão sem gerenciador de threads. Gerenciadores customizados ainda
não estão qualificados.

A próxima etapa é integrar esperas compatíveis, canais e serviços. Não há
dependência binária dos dois projetos de referência.

Consulte o [contrato](docs/periodic-contract.md), a [verificação](docs/verification.md)
e as [notas da versão](docs/release-notes.md).

Licença MIT.
