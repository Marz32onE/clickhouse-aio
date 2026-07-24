CHART_NAME ?= clickhouse-aio
RELEASE ?= ch-aio
NAMESPACE ?= clickhouse
VALUES ?= values.yaml

.PHONY: deps lint template template-dev package install install-dev uninstall

deps:
	helm dependency update

lint: deps
	helm lint .

template: deps
	helm template $(RELEASE) . -n $(NAMESPACE) -f $(VALUES) \
		--set cluster.clickhouse.defaultUser.password=changeme

template-dev: deps
	helm template $(RELEASE) . -n $(NAMESPACE) -f values-dev.yaml \
		--set cluster.clickhouse.defaultUser.password=changeme

package: deps lint
	helm package . --destination dist/

## Two-step install avoids CRD race on first apply
install-operator:
	helm upgrade --install $(RELEASE)-operator . -n clickhouse-operator-system --create-namespace \
		-f $(VALUES) --set cluster.enabled=false

install-cluster:
	helm upgrade --install $(RELEASE) . -n $(NAMESPACE) --create-namespace \
		-f $(VALUES) --set operator.enabled=false \
		--set cluster.clickhouse.defaultUser.password='$(PASSWORD)'

install: deps
	@test -n "$(PASSWORD)" || (echo 'Set PASSWORD=... for default user'; exit 1)
	helm upgrade --install $(RELEASE) . -n $(NAMESPACE) --create-namespace \
		-f $(VALUES) --set cluster.clickhouse.defaultUser.password='$(PASSWORD)'

install-dev: deps
	helm upgrade --install $(RELEASE) . -n $(NAMESPACE) --create-namespace \
		-f values-dev.yaml --set cluster.clickhouse.defaultUser.password='$(or $(PASSWORD),devpass)'

uninstall:
	helm uninstall $(RELEASE) -n $(NAMESPACE) || true
