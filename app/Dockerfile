FROM python:3.12-slim

WORKDIR /app

# flask: a aplicação · distro + instrumentação: o OpenTelemetry
RUN pip install --no-cache-dir \
      flask==3.0.3 \
      "opentelemetry-distro[otlp]" \
      opentelemetry-instrumentation-flask

COPY app.py .

ENV FLASK_APP=app.py \
    PYTHONUNBUFFERED=1 \
    APP_LOG_FILE=/var/log/app/checkout.log

EXPOSE 8080

# opentelemetry-instrument lê as variáveis OTEL_* e instrumenta o Flask
# sem nenhuma linha de código extra para HTTP, cliente HTTP e logging
CMD ["opentelemetry-instrument", "flask", "run", "--host=0.0.0.0", "--port=8080"]
