# ---------- Stage 1: build the Flutter web app ----------
FROM ghcr.io/cirruslabs/flutter:stable AS web
WORKDIR /src
COPY mobile/ ./
RUN flutter create --org com.lenden --platforms=web . \
 && flutter pub get \
 && flutter build web --release

# ---------- Stage 2: API + models, serving the web app at "/" ----------
FROM python:3.12-slim
WORKDIR /app
COPY requirements-api.txt .
RUN pip install --no-cache-dir -r requirements-api.txt

COPY src/ src/
COPY api/ api/
# Model registry artifacts: v3 (active by default) and the v2 model kept for comparison.
COPY artifacts/model_v3.joblib artifacts/model_fair.joblib artifacts/metrics_fair.json artifacts/demo_profiles.csv.gz artifacts/
COPY --from=web /src/build/web web/

ENV PYTHONPATH=/app/src \
    LENDEN_WEB_DIR=/app/web \
    LENDEN_DB=/app/var/lenden.db \
    LENDEN_SEED_DEMO=1
# Set in your host's dashboard, never in this file:
#   DATABASE_URL         Supabase session-pooler connection string
#   LENDEN_JWT_SECRET    long random value
#   RESEND_API_KEY       optional, to send real emails
#   SENTRY_DSN           optional, error tracking
EXPOSE 8000
# Migrations run first (also as Render's pre-deploy command); then the API starts.
CMD ["sh", "-c", "python -m lenden.migrate && uvicorn api.main:app --host 0.0.0.0 --port ${PORT:-8000} --proxy-headers --forwarded-allow-ips='*'"]
