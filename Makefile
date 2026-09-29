APP_NAME := integration-aggregator
NAMESPACE := integration
CHART := helm/integration-aggregator
IMAGE := integration-aggregator:local
OPENBAO_RELEASE := openbao
OPENBAO_CHART := openbao/openbao
OPENBAO_CHART_VERSION := 0.29.6
OPENBAO_VALUES := helm/openbao/values.yaml

.PHONY: up down test build load-image helm-lint \
        ensure-minikube install-openbao bootstrap-openbao

test:
	pytest -q

ensure-minikube:
	@command -v minikube >/dev/null || \
		(echo "ERROR: minikube is required"; exit 1)
	@minikube status >/dev/null 2>&1 || minikube start --driver=docker
	@kubectl cluster-info >/dev/null

install-openbao:
	@helm repo add openbao https://openbao.github.io/openbao-helm >/dev/null 2>&1 || true
	@helm repo update >/dev/null
	@helm upgrade --install $(OPENBAO_RELEASE) \
		$(OPENBAO_CHART) \
		--version $(OPENBAO_CHART_VERSION) \
		--namespace $(NAMESPACE) \
		--create-namespace \
		-f $(OPENBAO_VALUES)
	@kubectl wait \
		--namespace $(NAMESPACE) \
		--for=condition=Ready \
		pod/openbao-0 \
		--timeout=180s

bootstrap-openbao:
	./scripts/bootstrap-openbao.sh

build:
	docker build -t $(IMAGE) .

load-image: build
	minikube image load $(IMAGE)

helm-lint:
	helm lint $(CHART) \
		--set secret.existingSecret=integration-aggregator-openbao-token

up: ensure-minikube test helm-lint install-openbao bootstrap-openbao load-image
	@echo "Deploying $(APP_NAME)..."
	helm upgrade --install $(APP_NAME) \
		$(CHART) \
		--namespace $(NAMESPACE) \
		--create-namespace \
		--set image.repository=integration-aggregator \
		--set image.tag=local \
		--set image.pullPolicy=IfNotPresent \
		--set secret.existingSecret=integration-aggregator-openbao-token

	@echo "Waiting for deployment..."
	kubectl rollout status \
		deployment/$(APP_NAME) \
		-n $(NAMESPACE) \
		--timeout=120s

	@echo "Checking application health..."
	kubectl create job \
		$(APP_NAME)-healthcheck \
		--namespace $(NAMESPACE) \
		--image=curlimages/curl:8.10.1 \
		-- \
		curl --fail --silent \
		http://$(APP_NAME):8000/health

	kubectl wait \
		--namespace $(NAMESPACE) \
		--for=condition=complete \
		job/$(APP_NAME)-healthcheck \
		--timeout=60s

	kubectl logs \
		--namespace $(NAMESPACE) \
		job/$(APP_NAME)-healthcheck

	kubectl delete job \
		--namespace $(NAMESPACE) \
		$(APP_NAME)-healthcheck \
		--ignore-not-found

down:
	helm uninstall $(APP_NAME) \
		--namespace $(NAMESPACE) \
		--ignore-not-found

	helm uninstall $(OPENBAO_RELEASE) \
		--namespace $(NAMESPACE) \
		--ignore-not-found

	@echo "Application and OpenBao removed"
