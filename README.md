# Delphi Fiber Runtime

[![CI](https://github.com/ramonruanxc/delphi-fiber-runtime/actions/workflows/ci.yml/badge.svg)](https://github.com/ramonruanxc/delphi-fiber-runtime/actions/workflows/ci.yml)

Runtime Pascal em desenvolvimento, inspirado em virtual threads e nos projetos
[delphi-concurrent-pool](https://github.com/ramonruanxc/delphi-concurrent-pool) e
[delphi-service-host](https://github.com/ramonruanxc/delphi-service-host).

**Esta primeira entrega é um protótipo de agendamento periódico a 1 kHz.**
Ela implementa o núcleo de cadência fixa, temporizadores nativos canceláveis e
medição reproduzível. Fibers, suspensão de chamadas aninhadas, canais e integração
com o ciclo de vida de serviços são etapas posteriores do [projeto aprovado](docs/superpowers/specs/2026-09-10-delphi-fiber-runtime-design.md).

## O que já pode ser exercitado

- Deadlines monotônicos: `epoch + n * period`, sem acumular o tempo do callback.
- Uma execução ativa por agendamento; ciclos perdidos são descartados e contados.
- Windows: QPC e waitable timer; Linux: timerfd/eventfd; macOS: Mach clock/kqueue.
- Espera nativa até o deadline, sem loop periódico de `Sleep(1)` no agendador.
- CSV com deadline, início e fim; relatórios com percentis e ciclos descartados.
- CI multiplataforma, testes negativos com falha exata e releases por tag.

Bloquear um executor ocioso em uma espera nativa é esperado neste protótipo.
Uma futura tarefa lógica suspensa deverá liberar seu executor para outras tarefas.
Código bloqueante arbitrário ainda não recebe esse tratamento.

## Executar

Instale Free Pascal 3.2.2 e Python 3.12. No Linux, instale também as unidades FCL;
no macOS, o FPC pode ser instalado pelo Homebrew. Os comandos são iguais no
PowerShell e em shells Unix:

```text
python scripts/check.py
python scripts/package.py
```

O primeiro comando compila, executa os testes e mede dois cenários. Os dados
ficam em `build/check/`; o segundo cria os pacotes em `dist/` e compila um
consumidor extraído em um caminho com espaços. O empacotamento usa arquivos
rastreados pelo Git; execute a partir de um clone do repositório.

Para registrar CPU, memória e threads por amostragem, instale opcionalmente
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

Esse comando permite atraso de até 100 us em 99% dos ciclos planejados, contando
descartes como violações. O exemplo não é uma garantia do projeto. Registre
também hardware, duração, carga e configuração de energia para qualificar uso real.

## Portabilidade e próximos passos

A API separa política de agendamento e implementação do sistema operacional.
Compatibilidade universal não é presumida: cada combinação de compilador,
versão, sistema e CPU precisa de evidência própria na [matriz de suporte](docs/support-matrix.md).
Uma execução com FPC não valida Delphi.

A próxima etapa é experimentar contextos suspensíveis e validar exceções,
`try/finally`, tipos gerenciados e estado local por tarefa em cada backend.
Depois vêm esperas compatíveis, canais e serviços. Não há dependência binária dos
dois projetos de referência.

Consulte o [contrato](docs/periodic-contract.md), a [verificação](docs/verification.md)
e as [notas da versão](docs/release-notes.md).

Licença MIT.
