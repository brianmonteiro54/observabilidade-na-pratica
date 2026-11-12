"""Serviço de checkout de exemplo, instrumentado com OpenTelemetry.

Mostra, em um arquivo, as três coisas que a aula pede:
  1. span automático de HTTP (vem do opentelemetry-instrument, sem código);
  2. span manual com atributos de negócio (pedido.id);
  3. log em JSON carregando trace_id, para correlacionar no Loki.

Endpoints:
  POST /finalizar                 finaliza um pedido
  POST /_debug/fail?rate=0.3      passa a falhar em 30% das chamadas
  GET  /health
"""
import json
import logging
import os
import random
import time
from datetime import datetime, timezone

from flask import Flask, jsonify, request
from opentelemetry import metrics, trace
from opentelemetry.trace import Status, StatusCode

SERVICE = os.getenv("OTEL_SERVICE_NAME", "checkout")
LOG_FILE = os.getenv("APP_LOG_FILE", "/var/log/app/checkout.log")

tracer = trace.get_tracer(SERVICE)
meter = metrics.get_meter(SERVICE)

# métrica de negócio: é ela que detecta falha silenciosa
pedidos = meter.create_counter(
    "pedidos_finalizados",
    description="Pedidos que passaram pelo checkout, por resultado",
)

estado = {"fail_rate": float(os.getenv("FAIL_RATE", "0"))}


class JsonFormatter(logging.Formatter):
    """Uma linha de log = um JSON, já com o contexto do trace."""

    def format(self, record: logging.LogRecord) -> str:
        doc = {
            "ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
            "level": record.levelname.lower(),
            "service": SERVICE,
            "msg": record.getMessage(),
        }
        ctx = trace.get_current_span().get_span_context()
        if ctx.trace_id:
            doc["trace_id"] = format(ctx.trace_id, "032x")
            doc["span_id"] = format(ctx.span_id, "016x")
        doc.update(getattr(record, "campos", {}))
        # separadores compactos: o derived field do Grafana procura "trace_id":"..."
        return json.dumps(doc, ensure_ascii=False, separators=(",", ":"))


def _build_logger() -> logging.Logger:
    log = logging.getLogger(SERVICE)
    log.setLevel(logging.INFO)
    log.propagate = False
    destinos = [logging.StreamHandler()]
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        destinos.append(logging.FileHandler(LOG_FILE))
    except OSError:
        pass  # sem volume montado, segue só no stdout
    for handler in destinos:
        handler.setFormatter(JsonFormatter())
        log.addHandler(handler)
    return log


log = _build_logger()
app = Flask(__name__)


def reservar_estoque(pedido: str) -> None:
    """Dependência simulada: gera um span filho, como uma chamada real geraria."""
    with tracer.start_as_current_span("reservar_estoque") as span:
        span.set_attribute("pedido.id", pedido)
        time.sleep(random.uniform(0.005, 0.04))


def cobrar_pagamento(pedido: str) -> None:
    """O salto caro do trace: é ele que aparece como gargalo na cascata."""
    with tracer.start_as_current_span("cobrar_pagamento") as span:
        span.set_attribute("pedido.id", pedido)
        span.set_attribute("pagamento.metodo", "cartao")
        time.sleep(random.uniform(0.05, 0.25))


@app.post("/finalizar")
def finalizar():
    body = request.get_json(silent=True) or {}
    pedido = str(body.get("id", "sem-id"))
    itens = body.get("itens", [])

    # span manual: a operação de negócio, com os atributos do domínio
    with tracer.start_as_current_span("finalizar_pedido") as span:
        span.set_attribute("pedido.id", pedido)
        span.set_attribute("pedido.itens", len(itens))

        reservar_estoque(pedido)

        if random.random() < estado["fail_rate"]:
            erro = RuntimeError("pagamento recusado pelo emissor")
            span.record_exception(erro)
            span.set_status(Status(StatusCode.ERROR, "pagamento recusado"))
            pedidos.add(1, {"resultado": "erro"})
            log.error(
                "falha ao finalizar pedido",
                extra={"campos": {"pedido_id": pedido, "itens": len(itens)}},
            )
            return jsonify(erro="pagamento recusado"), 500

        cobrar_pagamento(pedido)
        span.set_attribute("pedido.aprovado", True)
        pedidos.add(1, {"resultado": "ok"})
        log.info(
            "pedido finalizado",
            extra={"campos": {"pedido_id": pedido, "itens": len(itens)}},
        )
        return jsonify(status="ok", pedido=pedido)


@app.post("/_debug/fail")
def debug_fail():
    """Injeta falha para a demonstração: /_debug/fail?rate=0.3"""
    estado["fail_rate"] = max(0.0, min(1.0, float(request.args.get("rate", 0))))
    log.info("fail_rate alterado", extra={"campos": {"fail_rate": estado["fail_rate"]}})
    return jsonify(fail_rate=estado["fail_rate"])


@app.get("/health")
def health():
    return jsonify(status="ok", service=SERVICE)
