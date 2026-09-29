# Design

## 1. Overview

The Integration Aggregator is a small internal OAuth integration service for connecting users to external providers such as GitHub and Google.

The service deliberately does not implement OAuth token exchange, token refresh, or token persistence itself. Those responsibilities are delegated to the OpenBao `oauthapp` secrets plugin.

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

## 2. Architecture

```text
                         +----------------------+
                         |      Client/User     |
                         +----------+-----------+
                                    |
                                    | HTTP
                                    v
                         +----------------------+
                         | Integration Aggregator|
                         |      FastAPI          |
                         +----------+-----------+
                                    |
                      +-------------+-------------+
                      |                           |
                      v                           v
              +---------------+          +---------------+
              | In-memory     |          |    OpenBao    |
              | provider/state|          |   oauthapp    |
              | request state |          |    plugin     |
              +---------------+          +-------+-------+
                                                |
                                                v
                                        +---------------+
                                        | GitHub/Google |
                                        | OAuth provider|
                                        +---------------+
