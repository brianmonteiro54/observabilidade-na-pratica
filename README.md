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

## O roteiro das demonstrações

```bash
./demo.sh 1     # telemetria saindo da aplicação e chegando no Collector
./demo.sh 2     # da métrica crua ao painel de erro
./demo.sh 3     # achar a linha de log que explica a falha
./demo.sh 4     # do log para o trace, e do trace de volta para o log
./demo.sh reset # desliga a injeção de falha
```

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

**Nenhum log no Loki.** O Collector lê `/var/log/app/*.log` do volume compartilhado:

```bash
docker compose exec otel-collector ls -la /var/log/app
docker compose logs loki | tail -20
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
