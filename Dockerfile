# ---------- Stage 1: build the Flutter web app ----------
FROM ghcr.io/cirruslabs/flutter:stable AS web
WORKDIR /src
COPY mobile/ ./
RUN flutter create --org com.lenden --platforms=web . \
 && flutter pub get \
 && flutter build web --release

# ---------- Stage 2: API + model, serving the web app at "/" ----------
FROM python:3.12-slim
WORKDIR /app
COPY requirements-api.txt .
RUN pip install --no-cache-dir -r requirements-api.txt

COPY src/ src/
COPY api/ api/
COPY artifacts/model_fair.joblib artifacts/model_fair.joblib
COPY --from=web /src/build/web web/

ENV PYTHONPATH=/app/src \
    LENDEN_WEB_DIR=/app/web \
    LENDEN_DB=/app/var/lenden.db \
    LENDEN_SEED_DEMO=1
# Set in your host's dashboard, never in this file:
#   DATABASE_URL           Supabase session-pooler connection string
#   LENDEN_JWT_SECRET   long random value
EXPOSE 8000
CMD ["sh", "-c", "uvicorn api.main:app --host 0.0.0.0 --port ${PORT:-8000}"]
