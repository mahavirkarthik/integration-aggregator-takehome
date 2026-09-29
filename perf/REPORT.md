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
| 2           | 30       | 30/30    | 76.723 ms | 253.824 ms | 18.07 req/s |
| 5           | 30       | 30/30    | 191.958 ms | 571.226 ms | 17.85 req/s |
| 10          | 30       | 30/30    | 176.844 ms | 365.577 ms | 88.12 req/s |

## Observations

All 90 benchmark requests returned HTTP 202 as expected.

The benchmark measures asynchronous request-submission latency and throughput.
The request endpoint returns immediately with a request ID while token
retrieval is handled asynchronously in the background.

Latency varied with concurrency in this local Minikube environment. The
throughput measurement also varied substantially between runs, so these
results should be treated as a local baseline rather than a production
capacity estimate.

The benchmark does not measure end-to-end OAuth/OpenBao token retrieval
completion time. Clients poll GET /requests/{id} to obtain the final request
status.

The performance provider is created or reused before the timed portion of
each benchmark run, so provider registration is excluded from the latency
and throughput measurements.
