# Design

## 1. Overview

The Integration Aggregator is a small internal OAuth integration service for
connecting users to external providers such as GitHub, Google, and OIDC.

The service deliberately does not implement OAuth token exchange, token refresh,
or token persistence itself. Those responsibilities are delegated to the
OpenBao `oauthapp` secrets plugin.

The application is responsible for:

- registering OAuth providers
- generating authorization URLs
- maintaining OAuth state during the authorization flow
- accepting OAuth callbacks
- creating asynchronous token retrieval requests
- exposing request status to clients

OpenBao is responsible for:

- storing OAuth client secrets
- performing authorization-code exchange
- storing OAuth credentials/tokens
- refreshing tokens when required

---

## 2. Architecture
                         +----------------------+
                         |      Client/User     |
                         +----------+-----------+
                                    |
                                    | HTTP
                                    v
                         +----------------------+
                         | Integration Aggregator|
                         |       FastAPI         |
                         +----------+-----------+
                                    |
                      +-------------+-------------+
                      |                           |
                      v                           v
              +---------------+          +---------------+
              |   In-memory   |          |    OpenBao    |
              | provider/state|          |   oauthapp    |
              | request state |          |    plugin     |
              +---------------+          +-------+-------+
                                                |
                                                v
                                        +---------------+
                                        | OAuth Provider|
                                        | GitHub/Google |
                                        |     /OIDC     |
                                        +---------------+

The application is stateless with respect to persistent business data.

Provider registrations, OAuth state, and asynchronous request state are held
in application memory.

OpenBao is the system of record for OAuth client secrets and OAuth credentials.


## 3. OAuth Responsibilities

The OAuth flow is intentionally divided between the Integration Aggregator
and the OpenBao OAuth plugin.

The application coordinates the OAuth flow but does not implement the OAuth
authorization-code exchange itself.

### Provider registration

A provider is registered through:


POST /providers

The request contains provider configuration, client ID, client secret, scopes,
and provider-specific options.

The Integration Aggregator passes the OAuth client configuration to OpenBao.

The client secret is therefore handled by OpenBao rather than being persisted
by the application.

The application keeps provider metadata required to process future requests.

### Connect flow

A user starts an OAuth connection through:

POST /providers/{provider}/users/{user}/connect


The application:

1. validates that the provider exists
2. generates a cryptographically random OAuth state value
3. stores the state and its provider/user association in memory
4. asks OpenBao for an authorization URL
5. returns the authorization URL to the caller

The client/browser then follows the authorization URL to the external OAuth
provider.

### Callback

The OAuth provider redirects the browser to:

GET /callback

The callback contains the authorization code and OAuth state.

The application validates the state against its in-memory state store.

Once the state is successfully validated, the application passes the
authorization code to OpenBao.

The OpenBao `oauthapp` plugin performs the authorization-code exchange and
stores the resulting credential.

The application does not implement or duplicate the provider-specific token
exchange logic.


## 4. API

The service exposes the following main endpoints.

### Register provider

POST /providers

Registers an OAuth provider and stores the provider's OAuth configuration
through OpenBao.

### Start user connection

POST /providers/{provider}/users/{user}/connect

Starts the OAuth authorization flow and returns the authorization URL.

### OAuth callback


GET /callback

Receives the OAuth authorization callback, validates the state, and passes the
authorization code to OpenBao.

### Retrieve user credential

GET /{provider}/{user}

Creates an asynchronous token retrieval request.

The endpoint returns:

```
202 Accepted
```

with a request ID and `Location` header.

### Request status

GET /requests/{id}


Returns the status of an asynchronous token retrieval request.

The request status response does not expose the OAuth access token or refresh
token.



## 5. Asynchronous Token Retrieval

Token retrieval is intentionally asynchronous.

When a client calls:


GET /{provider}/{user}

the application creates an asynchronous request and immediately returns:

```
HTTP 202 Accepted
```

The response contains:

* request ID
* request status
* provider
* user
* request status location

A background worker then retrieves the credential from OpenBao.

The final credential is not returned through the asynchronous status API.

The client polls:


GET /requests/{id}


until the request reaches a terminal state.

The current implementation keeps request state in application memory.

This satisfies the requirement that token retrieval is asynchronous while
avoiding persistent storage of request state.



## 6. Token Refresh

The Integration Aggregator does not implement its own token refresh mechanism.

Token freshness and refresh are delegated to the OpenBao `oauthapp` plugin.

The application retrieves credentials through OpenBao instead of maintaining
its own token cache.

This keeps OAuth provider-specific credential lifecycle logic outside the
application.

The service therefore does not implement:

* its own refresh-token exchange
* its own access-token cache
* provider-specific refresh logic

---

## 7. Data Placement

The design deliberately separates transient application state from sensitive
credential state.

### Application memory

The application stores transient information such as:

* provider metadata
* OAuth state
* provider/user association for active OAuth flows
* asynchronous request status
* asynchronous request errors

This state is not persisted to application files or a local database.

### OpenBao

OpenBao stores sensitive OAuth information including:

* OAuth client secrets
* OAuth credentials
* access tokens
* refresh tokens when supplied by the provider

The OAuth plugin owns the credential storage and refresh behavior.

### HTTP responses

OAuth access tokens and refresh tokens are not returned by the API.

The request status endpoint returns only request metadata and status information.



## 8. Secret Handling

The application uses a restricted OpenBao policy rather than the OpenBao root
token for normal application operations.

The application policy grants access to the paths required by the service:

```
oauth2/servers/*
oauth2/auth-code-url
oauth2/creds/*
```

The OpenBao root token is used only during local bootstrap.

The generated application token is stored in a Kubernetes Secret:

```
integration-aggregator-openbao-token
```

The application receives that token through a Kubernetes Secret reference.

Real OpenBao tokens, OAuth client secrets, access tokens, and refresh tokens are
not committed to the repository.

The local OAuth smoke and performance tests use non-production placeholder
credentials.



## 9. Kubernetes Architecture

The local environment runs on Minikube.

The deployment contains:

```
                         Minikube
                            |
                            v
                     integration namespace
                            |
             +--------------+--------------+
             |                             |
             v                             v
      +-------------+              +---------------+
      |   OpenBao   |              | Integration   |
      | StatefulSet |              |  Aggregator   |
      +------+------+              |  Deployment   |
             |                     +-------+-------+
             |                             |
             |                             v
             |                     +---------------+
             |                     |    Service    |
             |                     +---------------+
             |
             +-- oauthapp plugin
```

OpenBao is installed using its Helm chart.

The OAuth plugin is installed into the OpenBao pod through an init container.

The application is deployed using the project's Helm chart.

The application image is built locally and loaded into Minikube for local
development.

---

## 10. OpenBao Plugin Installation

The OpenBao Helm configuration uses an init container to download and install
the `oauthapp` plugin.

The plugin binary is downloaded from the project's release artifact and its
SHA-256 checksum is verified before installation.

The plugin is installed into:

```
/openbao/plugins/oauthapp
```

The OpenBao server is configured with:

```
plugin_directory = "/openbao/plugins"
```

During bootstrap, the plugin is registered and the OAuth secrets engine is
enabled at:

```
oauth2
```

The bootstrap process is idempotent for an already initialized and unsealed
local OpenBao instance.

---

## 11. Local OpenBao Configuration

The local OpenBao configuration uses:

* standalone mode
* file storage
* one OpenBao instance
* HTTP without TLS
* Kubernetes persistent storage
* the OAuth plugin installed in the pod

This configuration is intended for local development and CI rather than
production.

The development environment initializes OpenBao and creates a restricted
application token automatically.

The unseal key generated during initialization is not committed to the
repository.

If local OpenBao data is destroyed, OpenBao must be initialized again.

Production should use:

* highly available OpenBao
* durable storage
* TLS
* automatic or externally managed unsealing
* backup and recovery
* secret rotation
* appropriate network controls
* production access policies

---

## 12. Makefile and Local Deployment

The main local lifecycle is provided through:

```
make up
make down
```

`make up` performs the following steps:

1. ensures Minikube is available
2. runs the unit tests
3. validates the Helm chart
4. installs or upgrades OpenBao
5. waits for the OpenBao pod to start
6. initializes and unseals OpenBao when required
7. registers the OAuth plugin
8. enables the OAuth secrets engine
9. creates the restricted application policy
10. creates the application OpenBao token
11. stores the application token in a Kubernetes Secret
12. builds the application image
13. loads the image into Minikube
14. installs or upgrades the Integration Aggregator Helm release
15. waits for the application deployment
16. performs an application health check

`make down` removes the application and OpenBao Helm releases.

The development deployment is designed to be repeatable without manually
editing Kubernetes or OpenBao configuration.

---

## 13. Multi-Replica Limitation

The current implementation stores OAuth state and asynchronous request state
in application memory.

Therefore, the current service assumes a single application replica.

With multiple replicas, a request can be routed to a different instance from
the instance that originally created the in-memory state.

This can affect:

* OAuth callback state validation
* asynchronous request lookup
* asynchronous request status

For example:

```
                         Load Balancer
                              |
                 +------------+------------+
                 |                         |
                 v                         v
          +-------------+           +-------------+
          | Aggregator 1|           | Aggregator 2|
          +------+------+           +------+------+
                 |                         |
                 +------------+------------+
                              |
                              v
                       Shared state store
                       Redis / PostgreSQL
```

A production multi-replica implementation should move transient coordination
state into a shared datastore such as Redis or PostgreSQL.

The shared store would contain:

* OAuth state
* provider/user OAuth flow state
* asynchronous request state

OpenBao would remain responsible for OAuth credentials and tokens.

The assignment intentionally keeps the current implementation single-replica
and documents this limitation.

---

## 14. Failure Handling

The application handles common failure conditions including:

* unknown provider
* duplicate provider registration
* OpenBao communication failure
* invalid OAuth state
* token retrieval failure
* missing credential
* asynchronous request failure

Background retrieval failures transition the asynchronous request to a failed
state.

The API does not intentionally expose sensitive OpenBao information or token
values in normal error responses.

Sensitive credentials should not be logged.

---

## 15. OAuth State Security

OAuth state values are generated using a cryptographically secure random
generator.

The state is associated with the provider and user while the OAuth flow is
active.

The callback validates the state before accepting the authorization code.

After successful validation, the state is consumed from the in-memory state
store.

This prevents an arbitrary callback from being accepted without a matching
authorization flow.

---

## 16. CI/CD

The GitHub Actions workflow validates the project on pushes and pull requests.

The CI flow is:

```
                    GitHub Push / PR
                           |
             +-------------+-------------+
             |             |             |
             v             v             v
          Unit Tests   Helm Validation  Docker Build
             |             |             |
             +-------------+-------------+
                           |
                           v
                    Minikube E2E
                           |
             +-------------+-------------+
             |                           |
             v                           v
       Mock OIDC Provider          Application
             |                           |
             +-------------+-------------+
                           |
                           v
                    OAuth Smoke Test
                           |
                           v
                    Performance Test
                           |
                           v
                  Performance Artifact
                           |
                     Push only
                           |
                           v
                    GHCR Publication
```

### Unit tests

The workflow runs:

```
pytest -q
```

### Helm validation

The workflow performs:

```
helm lint
helm template
```

### Docker validation

The application Docker image is built as part of CI.

### Kubernetes E2E

CI starts Minikube and executes:

```
make up
```

The mock OIDC provider is then deployed into the cluster.

The application is port-forwarded locally and the full OAuth smoke test is
executed.

### Performance test

The performance script runs with multiple concurrency levels.

The results are uploaded as a GitHub Actions artifact.

### Publication

On push events, the publish job:

1. logs into GitHub Container Registry
2. builds the application Docker image
3. pushes the image to GHCR
4. packages the Helm chart
5. pushes the Helm chart to GHCR as an OCI artifact

The workflow uses `GITHUB_TOKEN` for registry authentication.

---

## 17. End-to-End Smoke Test

The CI smoke test uses a local OIDC provider rather than requiring interactive
consent from a real Google or GitHub account.

The flow is:

```
Client
  |
  | POST /providers
  v
Integration Aggregator
  |
  | provider configuration
  v
OpenBao
  |
  | authorization URL
  v
Integration Aggregator
  |
  | redirect
  v
Mock OIDC Provider
  |
  | authorization callback
  v
/callback
  |
  | authorization code
  v
OpenBao oauthapp plugin
  |
  | credential exchange/storage
  v
OpenBao
  |
  | asynchronous credential retrieval
  v
Integration Aggregator
  |
  | request status
  v
Client
```

The smoke test verifies that the complete flow reaches a completed
asynchronous request.

---

## 18. Performance Test

The performance test measures the asynchronous request-submission API:

GET /perf-oidc/perf-user

The endpoint returns `202 Accepted` immediately and creates a background
retrieval request.

The benchmark therefore measures:

* HTTP submission latency
* HTTP submission throughput
* successful `202` responses

It does not measure complete OAuth/OpenBao token retrieval latency.

Clients obtain the final request state through:


GET /requests/{id}

The benchmark is executed at multiple concurrency levels.

The results are recorded in:


perf/REPORT.md`

The benchmark runs against the local Minikube environment and should therefore
be treated as a local baseline rather than a production capacity measurement.

Provider registration is performed before the timed portion of the benchmark
so provider creation does not affect request-submission latency measurements.

---

## 19. Security Considerations

The implementation follows these security principles:

* OAuth state uses a cryptographically secure random generator.
* OAuth client secrets are handled by OpenBao.
* OAuth credentials are stored by the OpenBao OAuth plugin.
* The application uses a restricted OpenBao policy.
* The OpenBao root token is not used for normal application requests.
* Access tokens are not returned by the API.
* Refresh tokens are not returned by the API.
* Credentials are not written to repository files.
* Real credentials are not committed to the repository.
* OAuth callback state is validated before accepting authorization codes.
* The OAuth plugin binary is checksum-verified during installation.

The local OpenBao configuration disables TLS for development and CI simplicity.
Production deployment must use TLS and appropriate network restrictions.

---

## 20. Production Improvements

A production deployment should additionally consider:

* highly available OpenBao
* TLS between services
* automatic or externally managed OpenBao unsealing
* durable OpenBao storage
* OpenBao backup and disaster recovery
* secret rotation
* shared state for multiple application replicas
* Kubernetes NetworkPolicies
* workload identity where supported
* centralized structured logging
* metrics and tracing
* monitoring and alerting
* rate limiting
* stricter OAuth redirect URI validation
* production OAuth provider configuration
* security scanning
* dependency update automation

The current implementation intentionally keeps the take-home deployment
small and locally reproducible while documenting the changes required for a
production deployment.

