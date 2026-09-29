# Performance Report

## Scope

This benchmark measures the asynchronous token-retrieval API:

GET /github/test-user

The endpoint creates a background retrieval request and immediately returns
HTTP 202 Accepted with a request ID and Location header.

The benchmark therefore measures API submission latency and throughput, not
the end-to-end OAuth/OpenBao token retrieval completion time.

## Environment

- Kubernetes: Minikube
- Application: integration-aggregator
- Provider: GitHub
- User: test-user
- Requests per run: 30
- Benchmark tool: curl + xargs
- Local port-forward to the Kubernetes service

## Results

| Concurrency | Requests | HTTP 202 | p50 | p95 | Throughput |
|-------------|----------|----------|-----|-----|------------|
| 2           | 30       | 30/30    | 17.192 ms | 65.501 ms | 36.66 req/s |
| 5           | 30       | 30/30    | 89.032 ms | 138.832 ms | 43.49 req/s |
| 10          | 30       | 30/30    | 180.287 ms | 236.410 ms | 48.14 req/s |

## Observations

All 90 benchmark requests returned HTTP 202 as expected.

Throughput increased with concurrency, while p50 and p95 latency also
increased. The benchmark was run against a local Minikube deployment, so the
results are intended as a baseline rather than production capacity numbers.

The endpoint is asynchronous by design. Clients poll GET /requests/{id} to
obtain the final request status.
