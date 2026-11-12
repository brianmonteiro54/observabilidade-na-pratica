#!/usr/bin/env bash
# Comandos das quatro demonstrações da live, na ordem.
# Não rode tudo de uma vez: use ./demo.sh 1, ./demo.sh 2, etc.
set -uo pipefail

APP="${APP:-http://localhost:8080}"
PROM="${PROM:-http://localhost:9090}"

banner() { printf '\n\033[1;35m▸ %s\033[0m\n' "$*"; }
pausa()  { printf '\033[2m  (enter para seguir)\033[0m'; read -r _; }

pedido() {
  curl -s -o /dev/null -X POST "$APP/finalizar" \
    -H 'content-type: application/json' \
    -d "{\"id\":\"ped-$RANDOM\",\"itens\":[\"livro\",\"caneca\"]}"
}

# ---------------------------------------------------------------- demo 1
demo1() {
  banner "Demo 1 · telemetria saindo da aplicação e chegando no Collector"

  banner "o Collector está vivo?"
  curl -s "$APP/health"; echo
  curl -s http://localhost:13133; echo

  banner "uma requisição"
  curl -s -X POST "$APP/finalizar" -H 'content-type: application/json' \
       -d '{"id":"ped-0001","itens":["livro"]}'; echo

  banner "o span chegando no Collector (exporter debug)"
  docker compose logs --tail=120 otel-collector | grep -B2 -A8 "finalizar_pedido" | head -40

  banner "métricas internas do próprio Collector"
  curl -s localhost:8888/metrics | grep -E "otelcol_receiver_accepted|otelcol_exporter_sent" | head -8
}

# ---------------------------------------------------------------- demo 2
demo2() {
  banner "Demo 2 · da métrica crua ao painel de erro"

  banner "gerando carga"
  for _ in $(seq 1 40); do pedido; done
  echo "40 pedidos enviados"

  banner "a métrica crua, como o Prometheus guarda"
  curl -s "$PROM/api/v1/query" \
    --data-urlencode 'query=http_server_request_duration_seconds_count{service_name="checkout"}' \
    | head -c 600; echo

  banner "injetando 30% de falha"
  curl -s -X POST "$APP/_debug/fail?rate=0.3"; echo
  for _ in $(seq 1 40); do pedido; done

  banner "a taxa de erro, já calculada"
  for _ in $(seq 1 4); do
    curl -s "$PROM/api/v1/query" --data-urlencode 'query=
      sum(rate(http_server_request_duration_seconds_count{service_name="checkout",http_response_status_code=~"5.."}[1m]))
      / sum(rate(http_server_request_duration_seconds_count{service_name="checkout"}[1m]))' \
      | sed -E 's/.*"value":\[[0-9.]+,"([^"]*)".*/  taxa de erro: \1/' 
    sleep 10
  done

  echo
  echo "No Grafana → Dashboards → Aula → Observabilidade na Pratica"
  echo "Escreva no Explore, ao vivo:"
  echo '  histogram_quantile(0.95, sum by (le) (rate(http_server_request_duration_seconds_bucket[5m])))'
}

# ---------------------------------------------------------------- demo 3
demo3() {
  banner "Demo 3 · achar a linha de log que explica a falha"

  banner "garantindo que há erro no período"
  curl -s -X POST "$APP/_debug/fail?rate=0.5" >/dev/null
  for _ in $(seq 1 20); do pedido; done

  banner "a linha de log como a aplicação escreve (JSON, com trace_id)"
  docker compose exec -T otel-collector sh -c 'tail -3 /var/log/app/checkout.log' 2>/dev/null \
    || docker compose logs --tail=5 checkout

  echo
  echo "No Explore do Grafana, datasource Loki, nesta ordem:"
  echo '  {service_name="checkout"}'
  echo '  {service_name="checkout"} |= "error"'
  echo '  {service_name="checkout"} | json | level = "error"'
  echo '  sum by (level) (rate({service_name="checkout"} | json [5m]))'
  echo
  echo "Copie o trace_id de uma linha de erro: ele é o começo da demo 4."
}

# ---------------------------------------------------------------- demo 4
demo4() {
  banner "Demo 4 · do log para o trace, e do trace de volta para o log"

  banner "pegando um trace_id de um pedido que falhou"
  TRACE=$(docker compose exec -T otel-collector sh -c \
    'grep -h "\"level\": \"error\"" /var/log/app/checkout.log | tail -1' 2>/dev/null \
    | sed -E 's/.*"trace_id": "([a-f0-9]+)".*/\1/')
  echo "  trace_id: ${TRACE:-nenhum erro encontrado, rode ./demo.sh 3 primeiro}"

  echo
  echo "No Grafana → Explore → datasource Tempo:"
  echo "  1. cole o trace_id na busca por ID"
  echo "  2. abra a cascata e mostre o span mais caro (cobrar_pagamento)"
  echo "  3. abra os atributos e mostre pedido.id"
  echo "  4. use o botão de logs do span para voltar ao Loki"
  echo
  echo "E a busca por sintoma, sem saber o id, na aba TraceQL:"
  echo '  { resource.service.name = "checkout" && status = error }'
  echo '  { name = "finalizar_pedido" && duration > 300ms }'
  echo '  { span.pedido.id = "ped-0001" }'
  echo
  echo "Service Map: Explore → Tempo → aba Service Graph"
}

reset_demo() {
  banner "desligando a injeção de falha"
  curl -s -X POST "$APP/_debug/fail?rate=0"; echo
}

case "${1:-}" in
  1) demo1 ;;
  2) demo2 ;;
  3) demo3 ;;
  4) demo4 ;;
  reset) reset_demo ;;
  *) echo "uso: $0 {1|2|3|4|reset}"; exit 1 ;;
esac
