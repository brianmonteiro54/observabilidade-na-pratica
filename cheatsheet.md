# Cheatsheet — PromQL, LogQL, TraceQL e OpenTelemetry

## Nomes de métrica que o OTel gera

A conversão do OpenTelemetry para o Prometheus troca pontos por sublinhado e põe a unidade no nome:

| OpenTelemetry | Prometheus |
|---|---|
| `http.server.request.duration` (histograma, s) | `http_server_request_duration_seconds_bucket` / `_count` / `_sum` |
| `service.name` (atributo de recurso) | label `service_name` |
| `http.response.status_code` | label `http_response_status_code` |
| `http.route` | label `http_route` |
| contador `pedidos_finalizados` | `pedidos_finalizados_total` |

Se os nomes não baterem, o SDK pode estar usando a convenção antiga. Descubra o nome real:

```promql
{__name__=~"http.*"}
```

e, se precisar, ligue a convenção estável na aplicação: `OTEL_SEMCONV_STABILITY_OPT_IN=http`.

## PromQL

```promql
# tráfego por rota
sum by (http_route) (rate(http_server_request_duration_seconds_count{service_name="checkout"}[5m]))

# taxa de erro
  sum(rate(http_server_request_duration_seconds_count{service_name="checkout",http_response_status_code=~"5.."}[5m]))
/ sum(rate(http_server_request_duration_seconds_count{service_name="checkout"}[5m]))

# p95 (o label le precisa sobreviver ao by)
histogram_quantile(0.95, sum by (le, service_name) (rate(http_server_request_duration_seconds_bucket[5m])))

# métrica de negócio: pedidos aprovados por minuto
sum(rate(pedidos_finalizados_total{resultado="ok"}[5m])) * 60

# comparar duas versões em produção
histogram_quantile(0.95, sum by (le, service_version) (rate(http_server_request_duration_seconds_bucket[5m])))

# CPU por pod (Kubernetes)
sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="loja",container!=""}[5m]))

# contêineres reiniciando
increase(kube_pod_container_status_restarts_total{namespace="loja"}[15m]) > 0

# diagnóstico de cardinalidade: as 10 métricas com mais séries
topk(10, count by (__name__)({__name__=~".+"}))

# saúde da coleta
sum by (exporter) (rate(otelcol_exporter_send_failed_spans_total[5m]))
```

**Erros frequentes**

- `sum` antes de `rate` → número errado. A ordem é sempre `rate` primeiro.
- janela menor que 4× o intervalo de coleta → gráfico cheio de buracos.
- `histogram_quantile` sem `le` no `by` → sem resultado.
- `container!=""` ausente → a série agregada do pod entra na conta duas vezes.

## LogQL

```logql
# stream + filtro de linha
{service_name="checkout"} |= "error" != "healthcheck"

# parser e filtro por campo
{service_name="checkout"} | json | level = "error"

# todos os logs de um trace
{service_name="checkout"} | json | trace_id = "4bf92f3577b34da6a3ce929d0e0e4736"

# um pedido específico
{service_name="checkout"} | json | pedido_id = "ped-0001"

# log virando métrica: erros por segundo
sum by (level) (rate({service_name="checkout"} | json | __error__ = "" [5m]))

# p95 de um campo numérico do próprio log
quantile_over_time(0.95, {service_name="checkout"} | json | unwrap duration_ms [5m])

# extrair valor com regex quando não há JSON
{service_name="legado"} | regexp "pedido=(?P<pedido>[a-z0-9-]+)" | pedido = "ped-0001"
```

Os labels dependem de como o log chegou: pelo OTLP costumam ser `service_name` e `k8s_namespace_name`;
pelo Alloy ou Promtail, `namespace`, `app` e `pod`. Confira em **Explore → Label browser**.

## TraceQL

```traceql
# por serviço
{ resource.service.name = "checkout" }

# o que falhou
{ status = error }

# o que demorou
{ name = "finalizar_pedido" && duration > 300ms }

# erro em um serviço específico
{ resource.service.name = "checkout" && span.http.response.status_code >= 500 }

# o trace de um pedido: é o que resolve ticket de cliente
{ span.pedido.id = "ped-0001" }

# combinando condições de spans diferentes do mesmo trace
{ resource.service.name = "checkout" } && { name = "cobrar_pagamento" && duration > 200ms }
```

`resource.` consulta quem emitiu · `span.` consulta a operação. Os atributos de negócio que você
colocou no span viram filtro aqui — sem eles, não há o que consultar.

## Variáveis do SDK OpenTelemetry

```bash
OTEL_SERVICE_NAME=checkout                      # obrigatório na prática
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf       # ou grpc (porta 4317)
OTEL_RESOURCE_ATTRIBUTES=deployment.environment=prod,service.version=1.4.2
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.25
OTEL_PROPAGATORS=tracecontext,baggage
OTEL_TRACES_EXPORTER=otlp
OTEL_METRICS_EXPORTER=otlp
OTEL_LOGS_EXPORTER=otlp
OTEL_METRIC_EXPORT_INTERVAL=10000               # ms, útil para demonstração
OTEL_SEMCONV_STABILITY_OPT_IN=http              # nomes estáveis da convenção HTTP
OTEL_PYTHON_LOG_CORRELATION=true                # trace_id na linha de log (Python)
OTEL_SDK_DISABLED=false                         # chave geral
```

## Comandos úteis

```bash
# validar a configuração do Collector antes de aplicar
docker run --rm -v "$PWD/config:/c" otel/opentelemetry-collector-contrib:latest \
  validate --config=/c/otel-collector.yaml

# validar regras do Prometheus
promtool check rules k8s/07-servicemonitor.yaml

# ver o que o Collector está recebendo e perdendo
curl -s localhost:8888/metrics | grep -E "accepted|refused|failed"

# alvos e alertas sem abrir a interface
curl -s localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | [.labels.job, .health] | @tsv'
curl -s localhost:9090/api/v1/alerts  | jq -r '.data.alerts[] | [.labels.alertname, .state] | @tsv'

# plantão no Kubernetes
kubectl get events -A --sort-by=.lastTimestamp | tail -30
kubectl -n loja logs <pod> --previous --tail=100
```
