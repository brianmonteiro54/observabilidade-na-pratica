# Laboratório — Observabilidade na Prática

Stack completa de observabilidade rodando no seu notebook, com uma aplicação instrumentada de verdade.
É o ambiente usado nas quatro demonstrações da live.

```
OpenTelemetry (SDK)  →  OTel Collector  →  Prometheus (métricas)
                                        →  Loki       (logs)
                                        →  Tempo      (traces)
                                        →  Grafana    (uma tela para os três)
```

## Subir em dois comandos

```bash
cd lab
docker compose up -d --build
docker compose --profile carga up -d     # tráfego contínuo, para os gráficos terem vida
```

| Serviço | Endereço | Observação |
|---|---|---|
| Grafana | http://localhost:3000 | entra direto como admin, datasources e dashboard já provisionados |
| Aplicação | http://localhost:8080 | `POST /finalizar` · `POST /_debug/fail?rate=0.3` |
| Prometheus | http://localhost:9090 | veja `Status → Targets` |
| Collector | http://localhost:13133 | health · métricas internas em `:8888/metrics` |
| Loki | http://localhost:3100 | consulte pelo Grafana |
| Tempo | http://localhost:3200 | consulte pelo Grafana |

Primeira execução baixa as imagens e constrói a aplicação: reserve alguns minutos.
Para derrubar tudo, inclusive os dados: `docker compose down -v`.

## O que cada arquivo faz

| Arquivo | Papel |
|---|---|
| `docker-compose.yml` | amarra os seis contêineres e o volume de logs |
| `app/app.py` | aplicação de exemplo: span automático, span manual de negócio, log JSON com `trace_id` e métrica de negócio |
| `app/Dockerfile` | instala Flask e o OpenTelemetry; roda via `opentelemetry-instrument` |
| `config/otel-collector.yaml` | recebe OTLP, lê o log do arquivo e roteia os três sinais |
| `config/prometheus.yml` | observa a própria stack (as métricas da aplicação chegam por remote write) |
| `config/loki.yaml` | Loki em processo único, com ingestão OTLP habilitada |
| `config/tempo.yaml` | Tempo local, com metrics-generator alimentando o mapa de serviços |
| `config/grafana/datasources.yaml` | **onde a correlação é configurada**: exemplars, derived fields e trace-to-logs |
| `dashboards/observabilidade.json` | dashboard com SLO, RED, métrica de negócio e logs |
| `k8s/` | a mesma stack em Kubernetes, com Helm e o OpenTelemetry Operator |
| `demo.sh` | os comandos das quatro demonstrações, em ordem |
| `cheatsheet.md` | PromQL, LogQL, TraceQL e variáveis do OTel |

## Testes de verificação

Sete testes, de A a G, para rodar depois de subir a stack e antes de qualquer demonstração. Cada um
verifica **um trecho** do caminho da telemetria, na ordem em que o dado flui — então o primeiro que
falhar indica onde o caminho está quebrado. Todos rodam de dentro de `lab/`.

| Teste | O que faz | O que confirma |
|---|---|---|
| A | consulta o endpoint de saúde dos seis contêineres | todo mundo subiu e está respondendo |
| B | manda um pedido e dez em sequência | a aplicação funciona e gera telemetria |
| C | lista os nomes de métrica e lê o contador de negócio | aplicação → Collector → Prometheus |
| D | consulta os labels e as linhas do Loki | aplicação → arquivo → Collector → Loki |
| E | busca traces por serviço no Tempo | aplicação → Collector → Tempo |
| F | pega o `trace_id` do log e resolve no Tempo | **a correlação**, que é o que faz a stack valer |
| G | injeta falha e confere taxa de erro e p95 | o caminho de erro, que é o roteiro da demo 2 |

### Teste A · os seis componentes estão de pé

**O que faz.** Bate no endpoint de saúde de cada serviço. É o teste que separa "não subiu" de "subiu
e não funciona".

```bash
docker compose ps                      # seis serviços em Up (sete com o perfil carga)
curl -s localhost:8080/health          # {"service":"checkout","status":"ok"}
curl -s localhost:13133                # {"status":"Server available","upSince":"…","uptime":"…"}
curl -s localhost:9090/-/ready         # Prometheus Server is Ready.
curl -s localhost:3100/ready           # ready
curl -s localhost:3200/ready           # ready
curl -s localhost:3000/api/health      # {"database": "ok", "version": "13.3.1"}
```

**No Grafana.** Abra http://localhost:3000 — entra direto, sem login. Em
`Connections → Data sources` devem aparecer **três**: Prometheus, Loki e Tempo. Clique em
`Save & test` em cada um: os três respondem com sucesso. Se um datasource não existir, o
provisionamento não foi lido — confira a montagem de `config/grafana/` no `docker-compose.yml`.

O `/ready` do Loki às vezes insiste em `Ingester not ready: waiting for 15s after being ready`
mesmo com a stack de pé há horas. Não trate como falha: o teste que vale para o Loki é o D.

### Teste B · a aplicação responde e gera telemetria

**O que faz.** Manda um pedido nomeado, para você reconhecê-lo depois nos três sinais, e mais dez
para ter volume.

```bash
curl -s -X POST localhost:8080/finalizar \
  -H 'content-type: application/json' \
  -d '{"id":"ped-0001","itens":["livro","caneca"]}'
# esperado: {"pedido":"ped-0001","status":"ok"}

for i in $(seq 1 10); do
  curl -s -o /dev/null -X POST localhost:8080/finalizar \
    -H 'content-type: application/json' -d "{\"id\":\"ped-$i\",\"itens\":[\"a\"]}"
done
```

**No Grafana.** No dashboard, o painel **R · Requisicoes por segundo, por rota** ganha uma linha na
rota `/finalizar` em até 15 segundos. Se você rodou o perfil `carga`, a linha já está lá e sobe um
degrau.

### Teste C · a métrica chegou no Prometheus

**O que faz.** Lista os nomes de métrica que existem e lê o contador de negócio. É o teste do
caminho aplicação → Collector → remote write → Prometheus.

```bash
curl -s localhost:9090/api/v1/label/__name__/values \
  | tr ',' '\n' | tr -d '"[]' | grep -E 'http_server|pedidos|traces_'

curl -sG localhost:9090/api/v1/query \
  --data-urlencode 'query=sum by (resultado) (pedidos_finalizados_total)'
```

**O que deve aparecer.**

| Métrica | De onde vem | Para que serve |
|---|---|---|
| `http_server_request_duration_seconds_bucket` / `_count` / `_sum` | SDK na aplicação | taxa de erro, p95 e os painéis RED |
| `http_server_active_requests` | SDK na aplicação | requisições em voo |
| `pedidos_finalizados_total` | contador manual no `app.py` | a métrica de **negócio** |
| `traces_spanmetrics_calls_total`, `traces_spanmetrics_latency_*` | metrics-generator do Tempo | RED derivado dos spans, sem instrumentar nada a mais |
| `traces_service_graph_request_total` | metrics-generator do Tempo | alimenta o mapa de serviços |

**No Grafana.** `Explore → Prometheus` e escreva `pedidos_finalizados_total`: devem vir duas séries,
`resultado="ok"` e `resultado="erro"` (a segunda só existe se já houve falha). No dashboard, os três
números do topo saem de zero. Se as métricas `traces_*` não aparecerem, não é erro de configuração:
o metrics-generator do Tempo precisa de alguns minutos de tráfego.

### Teste D · o log chegou no Loki

**O que faz.** Pergunta ao Loki quais labels existem e devolve as últimas linhas do serviço. O
caminho aqui é diferente do da métrica: a aplicação escreve em `/var/log/app/checkout.log`, o
`filelog` do Collector lê o arquivo e exporta por OTLP.

```bash
curl -s localhost:3100/loki/api/v1/labels
# esperado: {"status":"success","data":["deployment_environment","service_name"]}

curl -sG localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={service_name="checkout"}' \
  --data-urlencode 'since=10m' --data-urlencode 'limit=3'
```

**A pegadinha.** A consulta olha, por padrão, **a última hora**. Sem tráfego nessa janela a resposta
vem com `"result":[]`, e isso **não** é pipeline quebrado. Gere carga e repita com `since=10m`.

**No Grafana.** `Explore → Loki → Label browser`: devem existir `service_name` e
`deployment_environment`. Escreva `{service_name="checkout"}` e confira que a linha chega em JSON,
com o campo `trace_id` dentro. No dashboard, o painel **Logs de erro em tempo real** fica vazio
enquanto não houver erro — ele filtra `level =~ "error|warning"`, e isso é o esperado em dia de paz.

### Teste E · o trace chegou no Tempo

**O que faz.** Busca traces do serviço em TraceQL, pela API.

```bash
curl -sG localhost:3200/api/search \
  --data-urlencode 'q={resource.service.name="checkout"}' --data-urlencode 'limit=3'
```

**O que deve aparecer.** Traces com `rootServiceName: checkout` e `rootTraceName: POST /finalizar`.
Um pedido bem-sucedido tem **quatro spans**:

| Span | Origem | Duração típica |
|---|---|---|
| `POST /finalizar` | automático, do `opentelemetry-instrument` | o total da requisição |
| `finalizar_pedido` | manual, com `pedido.id` e `pedido.itens` | 60 a 290 ms |
| `reservar_estoque` | manual, dependência simulada | 5 a 40 ms |
| `cobrar_pagamento` | manual, dependência simulada | 50 a 250 ms — o salto caro |

**No Grafana.** `Explore → Tempo → aba Search`, filtre por serviço `checkout` e abra qualquer trace:
a cascata mostra os quatro spans aninhados. Na aba **Service Graph** aparece o nó do checkout — e,
se estiver vazio, é falta de tráfego recente, não de configuração.

### Teste F · a correlação, que é o coração da stack

**O que faz.** Pega o `trace_id` da última linha de log e resolve esse trace no Tempo. Se este teste
passa, os três sinais estão falando da mesma requisição.

```bash
TRACE=$(docker compose exec -T checkout tail -1 /var/log/app/checkout.log \
  | sed -E 's/.*"trace_id": ?"([a-f0-9]+)".*/\1/')
echo "$TRACE"
curl -s -o /dev/null -w 'tempo http %{http_code}\n' "localhost:3200/api/traces/$TRACE"
# esperado: tempo http 200
```

A leitura é feita pelo contêiner da **aplicação** de propósito: a imagem do Collector é distroless e
não tem shell, então `docker compose exec otel-collector sh -c …` falha com
`exec: "sh": executable file not found`.

**No Grafana.** É aqui que você confere as três ligações que o `datasources.yaml` configura:

| Caminho | O que fazer | O que deve acontecer |
|---|---|---|
| log → trace | `Explore → Loki`, abrir uma linha de log | aparece o campo **TraceID** com o botão **Abrir trace** |
| trace → log | `Explore → Tempo`, abrir um span | aparece o botão de **logs** do span, que volta ao Loki filtrado |
| métrica → trace | dashboard, painel **D · Latencia p50, p95 e p99** | pontinhos de **exemplar** no gráfico; clicar abre o trace daquela requisição |

Se o botão **Abrir trace** não aparecer, o problema é `derivedFields` no datasource do Loki ou linha
de log sem `trace_id` — não é limitação da ferramenta.

### Teste G · o caminho de erro

**O que faz.** Injeta 50% de falha, gera carga, confere a taxa de erro e o p95, e desliga a falha.
É o ensaio da demo 2.

```bash
curl -s -X POST 'localhost:8080/_debug/fail?rate=0.5'
for i in $(seq 1 30); do
  curl -s -o /dev/null -X POST localhost:8080/finalizar \
    -H 'content-type: application/json' -d "{\"id\":\"ped-err-$i\",\"itens\":[\"x\"]}"
done
sleep 15
curl -s -X POST 'localhost:8080/_debug/fail?rate=0'      # NÃO esqueça de desligar
```

**Medido nesta stack:** taxa de erro **0,45** com `rate=0.5` injetado, p95 de **0,35 s** e o contador
de negócio em 41 pedidos `ok` contra 19 `erro`. Ordem de grandeza é o que importa — a taxa oscila
conforme a janela.

**No Grafana.** Com a falha ligada, cinco pontos da tela mudam:

| Onde | O que deve acontecer |
|---|---|
| **Taxa de erro · 5 min** | sai do verde e vai para **vermelho** (o limite vermelho é 5%) |
| **E · Erros por status** | surge a barra `500` empilhada ao lado da `200` |
| **Negocio · pedidos por resultado** | surge a série `erro` ao lado da `ok` |
| **Pedidos finalizados por minuto** | **cai**, porque conta só `resultado="ok"` |
| **Logs de erro em tempo real** | começa a rolar com as linhas `level=error` e a mensagem `falha ao finalizar pedido` |

Depois do `rate=0`, os painéis voltam ao normal em cerca de cinco minutos — é a janela de `[5m]` das
consultas esvaziando.

### Verificação em um comando

Salve como `verifica.sh`, dê `chmod +x` e rode antes de qualquer aula. É o resumo dos testes A a F.

```bash
#!/usr/bin/env bash
set -u
ok(){ printf '  ok    %s\n' "$1"; }
no(){ printf '  FALHA %s\n' "$1"; }
chk(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else no "$1"; fi; }

echo "1 · saude dos componentes"
chk "aplicacao  :8080"  'curl -sf localhost:8080/health'
chk "collector  :13133" 'curl -sf localhost:13133'
chk "prometheus :9090"  'curl -sf localhost:9090/-/ready'
chk "loki       :3100"  'curl -sf -G localhost:3100/loki/api/v1/labels'
chk "tempo      :3200"  'curl -sf localhost:3200/ready'
chk "grafana    :3000"  'curl -sf localhost:3000/api/health'

echo "2 · gerando 10 pedidos"
for i in $(seq 1 10); do
  curl -s -o /dev/null -X POST localhost:8080/finalizar \
    -H 'content-type: application/json' -d "{\"id\":\"ped-smoke-$i\",\"itens\":[\"a\"]}"
done
sleep 12

echo "3 · os tres sinais e a correlacao"
curl -sG localhost:9090/api/v1/query \
  --data-urlencode 'query=sum(pedidos_finalizados_total)' \
  | grep -q '"value"' && ok "metrica no Prometheus" || no "metrica no Prometheus"

curl -sG localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={service_name="checkout"}' \
  --data-urlencode 'since=10m' --data-urlencode 'limit=1' \
  | grep -q '"values"' && ok "log no Loki" || no "log no Loki"

TRACE=$(docker compose exec -T checkout tail -1 /var/log/app/checkout.log \
  | sed -E 's/.*"trace_id": ?"([a-f0-9]+)".*/\1/')
curl -sf -o /dev/null "localhost:3200/api/traces/$TRACE" \
  && ok "trace $TRACE no Tempo" || no "trace nao encontrado no Tempo"
```

### Checklist de aprovação

Se os dez itens passam, a stack está pronta para a demonstração.

| # | O que precisa estar verdadeiro | Como você sabe |
|---|---|---|
| 1 | seis contêineres de pé | `docker compose ps` sem `Exit` nem `Restarting` |
| 2 | a aplicação responde | `/health` devolve `status: ok` |
| 3 | o Collector está vivo e sem erro de configuração | `:13133` responde e `docker compose logs otel-collector` não tem `error` recente |
| 4 | a telemetria entra no Collector | `curl -s localhost:8888/metrics \| grep otelcol_receiver_accepted` cresce |
| 5 | a telemetria sai do Collector | `otelcol_exporter_sent_spans`, `_metric_points` e `_log_records` crescem |
| 6 | métrica da aplicação no Prometheus | `pedidos_finalizados_total` devolve valor |
| 7 | log no Loki | consulta com `since=10m` devolve linhas |
| 8 | trace no Tempo | busca TraceQL por serviço devolve traces |
| 9 | correlação | o `trace_id` do log resolve com HTTP 200 em `/api/traces/` |
| 10 | Grafana pronto | três datasources e o dashboard `obs-na-pratica` com dado nos nove painéis |

## O que você vê no Grafana

Entra direto em http://localhost:3000, sem login: o `docker-compose.yml` liga acesso anônimo com
papel de admin. O dashboard já vem provisionado em `Dashboards → Aula → Observabilidade na Pratica ·
checkout`, ou direto em http://localhost:3000/d/obs-na-pratica.

O dashboard atualiza a cada **10 segundos**, mostra a **última 15 minutos** e tem no topo a
variável `$service`, preenchida com `label_values(http_server_request_duration_seconds_count,
service_name)` — ou seja, a lista de serviços vem da própria métrica. Em uma stack só com o
laboratório, o único valor é `checkout`.

### Os nove painéis

| Painel | O que mostra | O que você deve ver em dia normal | Como reage à falha injetada |
|---|---|---|---|
| **Pedidos finalizados por minuto** | `pedidos_finalizados_total{resultado="ok"}` por minuto | com o perfil `carga` ligado, um valor estável e bem acima de 1, em verde; sem carga, vai a zero e o painel fica **vermelho** (o limite verde é 1/min) | **cai**, porque conta só o resultado `ok` |
| **Taxa de erro · 5 min** | 5xx sobre o total, em percentual | `0,00%`, verde | âmbar acima de 1%, vermelho acima de 5%; com 50% injetado, medi **0,475** |
| **Latencia p95** | p95 em segundos | entre **0,30 s e 0,45 s** (medi 0,417 s). Como o limite âmbar é 0,3 s, é normal este painel ficar **âmbar mesmo saudável** | **cai** para perto de 0,31 s — erro é mais rápido que sucesso, porque falha antes de cobrar |
| **R · Requisicoes por segundo, por rota** | tráfego por `http_route` | uma linha para `/finalizar`, estável | não muda de forma: o tráfego continua chegando |
| **E · Erros por status** | barras empilhadas por código `[45]..` | vazio | surge a barra `500` |
| **D · Latencia p50, p95 e p99** | as três curvas de latência | p50 perto de **0,17 s** e p99 perto de **0,48 s** — é a cauda que o slide 9 explica | o p50 despenca para **0,08 s** e a distância entre as curvas aumenta |
| **Negocio · pedidos por resultado** | `pedidos_finalizados_total` por `resultado`, por minuto | só a série `ok` | surge a série `erro` |
| **Saude da coleta** | deveria mostrar spans aceitos e recusados pelo Collector | **`No data`** — o painel está com defeito, veja abaixo | nada, pelo mesmo motivo |
| **Logs de erro em tempo real** | `{service_name="$service"} \| json \| level =~ "error\|warning"` | vazio | rola com as linhas `falha ao finalizar pedido` |

Dois painéis merecem narração na aula. O **p95 âmbar em dia saudável** é a conversa sobre limite mal
calibrado: o número está certo, a meta é que foi escolhida no chute. E vale mostrar que o p95 de
0,417 s vem de interpolação dentro do bucket de 250 ms a 500 ms do histograma — percentil tem a
resolução das faixas que você escolheu, e isso raramente aparece em slide.

**O painel "Saude da coleta" não funciona como está.** As duas consultas pedem
`otelcol_exporter_send_failed_spans_total` e `otelcol_receiver_accepted_spans_total`, mas a
telemetria interna do Collector 0.165 expõe esses contadores **sem o sufixo `_total`**. Confirmado
na stack: os nomes que existem são `otelcol_receiver_accepted_spans`, `otelcol_exporter_sent_spans`
e `otelcol_exporter_send_failed_metric_points`. As consultas que devolvem dado são:

```promql
# spans aceitos, por receiver
sum by (receiver) (rate(otelcol_receiver_accepted_spans[5m]))

# qualquer envio que falhou, por exporter · a série só existe depois da primeira falha
sum by (exporter) (rate({__name__=~"otelcol_exporter_send_failed_.*"}[5m]))
```

Enquanto o painel não for corrigido, use o terminal para a mesma resposta:

```bash
curl -s localhost:8888/metrics | grep -E 'otelcol_(receiver_accepted|exporter_sent|exporter_send_failed)'
```

Vale consertar antes da aula, porque é o painel que responde "como eu sei que a minha observabilidade
está funcionando?" — a stack de observabilidade também precisa ser observada.

### Os três caminhos de correlação

Tudo configurado em `config/grafana/datasources.yaml`. É isso que transforma três ferramentas em uma
investigação, e nenhum deles é automático:

| Caminho | Onde clicar | O que está por trás |
|---|---|---|
| **métrica → trace** | os pontinhos no painel **D · Latencia** | `exemplarTraceIdDestinations` no Prometheus, com `--enable-feature=exemplar-storage` |
| **log → trace** | o campo **TraceID** ao abrir uma linha de log | `derivedFields` no Loki, com a regex `"trace_id":"(\w+)"` |
| **trace → log** | o botão de logs dentro de um span | `tracesToLogsV2` no Tempo, filtrando por `trace_id` |
| **trace → mapa** | `Explore → Tempo → aba Service Graph` | `serviceMap` e `nodeGraph`, alimentados pelo metrics-generator |

### No Explore

É onde a aula acontece de verdade, porque dá para escrever consulta na frente da turma:

| Datasource | Aba que importa | O que usar |
|---|---|---|
| Prometheus | Builder ou Code | PromQL; comece pela métrica crua e vá montando o `rate` |
| Loki | Code, com **Label browser** ao lado | LogQL; o `Label browser` mostra que os labels vêm do OTLP |
| Tempo | **Search**, **TraceQL** e **Service Graph** | buscar por serviço, por `trace_id` ou por sintoma |

## O roteiro das demonstrações

Quatro demonstrações, cada uma respondendo uma pergunta de incidente. Rode **uma por vez**: o
`demo.sh` não foi feito para ir do começo ao fim de uma vez.

| Demo | Pergunta que responde | Comando | Sinal | Tempo |
|---|---|---|---|---|
| 1 | a telemetria está saindo e chegando? | `./demo.sh 1` | — | ~5 min |
| 2 | está quebrado? | `./demo.sh 2` | métrica | ~9 min |
| 3 | por que quebrou? | `./demo.sh 3` | log | ~8 min |
| 4 | onde quebrou, e qual caso? | `./demo.sh 4` | trace | ~9 min |
| — | desliga a injeção de falha | `./demo.sh reset` | — | — |

Antes de começar, deixe a carga rodando por alguns minutos (`docker compose --profile carga up -d`):
os gráficos precisam de história e o mapa de serviços precisa de tráfego.

---

### Demo 1 · a telemetria chega no Collector

```bash
./demo.sh 1
```

| Passo | O que o script faz | O que deve acontecer |
|---|---|---|
| 1 | `curl -s localhost:8080/health` | `{"service":"checkout","status":"ok"}` |
| 2 | `curl -s localhost:13133` | `{"status":"Server available","upSince":"…","uptime":"…"}` |
| 3 | `POST /finalizar` com `ped-0001` | `{"pedido":"ped-0001","status":"ok"}` |
| 4 | procura o span no log do Collector | a linha do exporter `debug`, com nome do span, `trace_id`, `span_id` e os atributos de negócio |
| 5 | lê `localhost:8888/metrics` | os contadores `otelcol_receiver_accepted_spans` e `otelcol_exporter_sent_spans` com valores próximos |

O passo 4 é este comando, e vale rodar na mão se quiser repetir:

```bash
docker compose logs --tail=120 otel-collector | grep -B2 -A8 finalizar_pedido
```

A linha que interessa é o span manual da aplicação, visto de dentro do Collector. Ela vem em uma
linha só, com nome, `trace_id`, `span_id` e os atributos de negócio:

```text
finalizar_pedido 788251009db8a297777740a8f17e4cd3 7ac697c638459f98 pedido.id=ped-0001 pedido.itens=1 pedido.aprovado=true
```

Logo acima dela aparece o bloco `ResourceTraces`, com `service.name=checkout`,
`service.version=1.0.0` e `deployment.environment=lab` — é o **resource** do slide 18 chegando no
Collector, e é um bom momento para apontar isso na tela.

**O que mostrar depois dos comandos.** Abra `config/otel-collector.yaml` no editor e percorra a
anatomia do arquivo: `receivers` (OTLP e `filelog`), `processors` (`memory_limiter`, `resource`,
`batch`), `exporters` (Tempo, Prometheus e Loki) e, no fim, as **três pipelines**. É a resposta
prática para "e se amanhã eu trocar de ferramenta?": muda-se o exporter, não o código.

**Se o span não aparecer no passo 4.** O exporter `debug` está amostrado
(`sampling_initial: 2`, `sampling_thereafter: 200`): ele não imprime todo lote. Mande outra
requisição e repita o `grep`. Se continuar vazio, confira se o Collector está recebendo:

```bash
curl -s localhost:8888/metrics | grep otelcol_receiver_accepted_spans
```

---

### Demo 2 · da métrica crua ao painel de erro

```bash
./demo.sh 2
```

O script gera 40 pedidos, injeta 30% de falha e imprime a taxa de erro quatro vezes, a cada 10
segundos. O valor deve sair de perto de zero e estabilizar em torno de **0,3**.

**A sequência para escrever ao vivo**, no Explore do Grafana com o datasource Prometheus. Escreva
na ordem, uma por vez, dizendo o que mudou:

| Ordem | Consulta | O que deve acontecer |
|---|---|---|
| 1 | `http_server_request_duration_seconds_count{service_name="checkout"}` | um número que só cresce — é contador, o valor absoluto não serve para nada |
| 2 | `rate(http_server_request_duration_seconds_count{service_name="checkout"}[1m])` | requisições por segundo, uma linha por combinação de rota e status |
| 3 | a divisão dos 5xx pelo total (abaixo) | a taxa de erro, de 0 a 1; com falha injetada em 0.3, fica perto de 0,3 |
| 4 | `histogram_quantile(0.95, sum by (le) (rate(http_server_request_duration_seconds_bucket[5m])))` | o p95 em segundos — no lab, entre 0,25 e 0,40 |

```promql
  sum(rate(http_server_request_duration_seconds_count{service_name="checkout",
        http_response_status_code=~"5.."}[1m]))
/ sum(rate(http_server_request_duration_seconds_count{service_name="checkout"}[1m]))
```

**No dashboard.** `Dashboards → Aula → Observabilidade na Pratica · checkout`, ou direto em
http://localhost:3000/d/obs-na-pratica. Com a falha injetada, quatro painéis reagem:

| Painel | Consulta por trás | Como reage |
|---|---|---|
| Taxa de erro · 5 min | 5xx sobre o total | sobe para perto de 0,3 |
| E · Erros por status | `sum by (http_response_status_code)` dos `[45]..` | ganha a série `500` |
| Negocio · pedidos por resultado | `sum by (resultado) (rate(pedidos_finalizados_total[5m])) * 60` | aparece a série `erro` ao lado da `ok` |
| Pedidos finalizados por minuto | só o `resultado="ok"`, vezes 60 | **cai** |

O último é o painel que vale explicar com calma: ele conta pedido finalizado com sucesso, não
requisição HTTP. É o tipo de métrica que detecta falha silenciosa, porque não depende do código de
status que a aplicação devolve.

**Erros de PromQL que valem errar de propósito.** `sum` antes de `rate` devolve número errado e
convincente; `histogram_quantile` sem `le` no `by` não devolve nada. Errar e corrigir na frente da
turma ensina mais que painel pronto.

**Se o gráfico não reagir.** São dois atrasos somados: o SDK exporta métrica a cada 10 s
(`OTEL_METRIC_EXPORT_INTERVAL`) e a janela do `rate` é de 1 min. Espere meio minuto antes de
suspeitar da stack.

---

### Demo 3 · a linha de log que explica a falha

```bash
./demo.sh 3
```

O script sobe a falha para 50%, manda 20 pedidos e imprime as últimas linhas de log. A linha que
interessa é esta, e o campo que importa é o último:

```json
{"ts":"2026-11-12T22:22:29.153+00:00","level":"error","service":"checkout",
 "msg":"falha ao finalizar pedido","trace_id":"56ec5c6e00bede91dc4309d8785c537a",
 "span_id":"cd90ce77765f92ec","pedido_id":"ped-0001","itens":1}
```

O script tenta ler o arquivo pelo contêiner do Collector, que **não tem shell** — a imagem é
distroless. Quando isso falhar, leia pelo contêiner da aplicação, que monta o mesmo volume:

```bash
docker compose exec -T checkout tail -3 /var/log/app/checkout.log
```

**A sequência para escrever ao vivo**, no Explore com o datasource Loki. O ponto da demo é o
estreitamento progressivo:

| Ordem | Consulta | O que deve acontecer |
|---|---|---|
| 1 | `{service_name="checkout"}` | todas as linhas do serviço, muita coisa e pouca informação |
| 2 | `{service_name="checkout"} \|= "error"` | só as linhas que contêm a palavra — filtro de texto, frágil |
| 3 | `{service_name="checkout"} \| json \| level = "error"` | filtro por **campo**: é a diferença entre a caixa de sapato e a planilha |
| 4 | `sum by (level) (rate({service_name="checkout"} \| json [5m]))` | o log virando métrica: uma série por nível — com a falha injetada, `info` e `error` — e você pode alertar nisso |
| 5 | `{service_name="checkout"} \| json \| pedido_id = "ped-0001"` | o caso individual, que é o que resolve ticket de cliente |

Na linha de erro, o Grafana mostra o botão **Abrir trace** — é o `derivedFields` do datasource,
configurado em `config/grafana/datasources.yaml`. **Copie o `trace_id`**: ele é o começo da demo 4.

**Se não vier nada.** Antes de desconfiar do pipeline, confira a janela de tempo: o padrão do
Explore é a última hora e, sem tráfego recente, o resultado vem vazio. Gere carga e repita.

---

### Demo 4 · do log para o trace, e do trace de volta para o log

```bash
./demo.sh 4
```

O script imprime um `trace_id` de pedido que falhou. A extração dele depende de ler o arquivo de
log, então se vier vazio use:

```bash
TRACE=$(docker compose exec -T checkout sh -c \
  'grep -E "\"level\": ?\"error\"" /var/log/app/checkout.log | tail -1' \
  | sed -E 's/.*"trace_id": ?"([a-f0-9]+)".*/\1/')
echo "$TRACE"
```

**No Explore com o datasource Tempo**, nesta ordem:

| Passo | O que fazer | O que deve acontecer |
|---|---|---|
| 1 | colar o `trace_id` na busca por ID | abre a cascata da requisição |
| 2 | ler a cascata de um pedido **com erro** | só `POST /finalizar`, `finalizar_pedido` e `reservar_estoque`; `finalizar_pedido` com status de erro e a mensagem `pagamento recusado` |
| 3 | abrir a cascata de um pedido **que deu certo** | quatro spans, e `cobrar_pagamento` como o mais longo — de 50 a 250 ms |
| 4 | abrir os atributos do span | `pedido.id`, `pedido.itens`, `pedido.aprovado` |
| 5 | clicar no botão de logs do span | volta ao Loki filtrado por aquela requisição — é o `tracesToLogsV2` |
| 6 | aba **Service Graph** | o grafo de quem chama quem, derivado dos spans pelo metrics-generator |

O contraste do passo 2 com o passo 3 é o melhor momento da demonstração: no trace do erro a cascata
**para** antes da cobrança, e isso se lê na tela sem precisar abrir código.

**E a busca por sintoma**, quando não se tem nenhum id na mão — aba TraceQL:

```traceql
{ resource.service.name = "checkout" && status = error }
{ name = "finalizar_pedido" && duration > 200ms }
{ span.pedido.id = "ped-0001" }
```

| Consulta | O que deve acontecer |
|---|---|
| `status = error` | lista de traces com raiz `POST /finalizar`; só devolve algo se houver falha injetada na janela |
| `duration > 200ms` | alguns traces, porque `cobrar_pagamento` dorme de 50 a 250 ms. **Não use `300ms` aqui**: no lab, `finalizar_pedido` raramente passa de 290 ms e a busca volta vazia — o `demo.sh` e o cheatsheet usam esse valor, que é bom em produção e ruim para demonstração |
| `span.pedido.id` | o trace daquele pedido, desde que o id exista na janela. É o atributo de negócio virando filtro |

**Se o Service Graph estiver vazio.** Ele vem do metrics-generator do Tempo, que precisa de alguns
minutos de tráfego. Confira se a série existe antes de culpar a configuração:

```bash
curl -sG localhost:9090/api/v1/query \
  --data-urlencode 'query=sum(traces_service_graph_request_total)'
```

---

### Depois das demonstrações

```bash
./demo.sh reset    # devolve fail_rate para 0
```

Rode sempre. Deixar a injeção de falha ligada estraga o gráfico de abertura da próxima
demonstração — e assusta quem for olhar o dashboard depois.

## Se algo não aparecer

**Nenhuma métrica no Prometheus.** O caminho é a aplicação → Collector → remote write. Verifique nesta ordem:

```bash
curl -s localhost:13133                               # o Collector está vivo?
docker compose logs otel-collector | tail -30         # erro de configuração?
curl -s localhost:8888/metrics | grep otelcol_exporter_send_failed
```

**O nome da métrica não é o que está no slide.** Depende da versão do SDK e da convenção em uso.
Descubra o nome real no Explore do Grafana:

```promql
{__name__=~"http.*"}
```

Ajuste o dashboard se necessário — o lab já pede os nomes estáveis com `OTEL_SEMCONV_STABILITY_OPT_IN=http`.

**Nenhum log no Loki.** Primeiro confira a janela de tempo: o Explore olha a última hora por padrão
e, sem tráfego recente, o resultado vem vazio sem que nada esteja quebrado. Depois confira o
arquivo que o `filelog` lê no volume compartilhado — a leitura é pelo contêiner da **aplicação**,
porque a imagem do Collector é distroless e não tem `sh` nem `ls`:

```bash
docker compose exec -T checkout ls -la /var/log/app
docker compose exec -T checkout tail -3 /var/log/app/checkout.log
docker compose logs loki | tail -20
curl -s localhost:8888/metrics | grep -E 'filelog|otlphttp'   # o Collector leu e enviou?
```

**O link do log para o trace não aparece.** É configuração de datasource, não mágica da ferramenta:
confira `derivedFields` em `config/grafana/datasources.yaml` e se a linha de log realmente tem `trace_id`.

**O mapa de serviços está vazio.** Ele vem do metrics-generator do Tempo, que precisa de alguns minutos
de tráfego e dos processors `service-graphs` e `span-metrics` ativos.

## Versão em Kubernetes

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

kubectl apply -f k8s/01-namespace.yaml
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n observability -f k8s/02-kube-prometheus-stack.values.yaml
helm upgrade --install loki  grafana/loki  -n observability -f k8s/03-loki.values.yaml
helm upgrade --install tempo grafana/tempo -n observability -f k8s/04-tempo.values.yaml
helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
  -n observability --set manager.collectorImage.repository=otel/opentelemetry-collector-contrib

kubectl apply -f k8s/05-otel-collector.yaml
kubectl apply -f k8s/06-instrumentation.yaml
kubectl apply -f k8s/07-servicemonitor.yaml
```

As chaves de `values.yaml` mudam entre versões de chart. Quando algo não for aceito, a fonte da verdade é:

```bash
helm show values grafana/loki | less
```
