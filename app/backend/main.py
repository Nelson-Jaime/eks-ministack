## Testing CI/CD

import os
import time

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from starlette.requests import Request
from starlette.responses import Response

app = FastAPI(title="EKS MiniStack API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "status"],
)
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency",
    ["endpoint"],
)


@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    start = time.time()
    response = await call_next(request)
    duration = time.time() - start
    REQUEST_LATENCY.labels(endpoint=request.url.path).observe(duration)
    REQUEST_COUNT.labels(
        method=request.method,
        endpoint=request.url.path,
        status=response.status_code,
    ).inc()
    return response


@app.get("/")
def root():
    return {
        "message": "EKS MiniStack API",
        "pod": os.getenv("POD_NAME", "local"),
        "version": os.getenv("APP_VERSION", "dev"),
        "node": os.getenv("NODE_NAME", "unknown"),
    }


@app.get("/health")
def health():
    return {"status": "ok", "version": os.getenv("APP_VERSION", "dev")}


@app.get("/ready")
def ready():
    return {"ready": True}


@app.get("/info")
def info():
    return {
        "pod": os.getenv("POD_NAME", "local"),
        "node": os.getenv("NODE_NAME", "unknown"),
        "namespace": os.getenv("POD_NAMESPACE", "default"),
        "version": os.getenv("APP_VERSION", "dev"),
        "zone": os.getenv("NODE_ZONE", "unknown"),
    }


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
