CHART_NAME ?= clickhouse
RELEASE ?= ch-aio
NAMESPACE ?= clickhouse
VALUES ?= values.yaml

.PHONY: deps lint template package install install-operator install-cluster uninstall

deps:
	helm dependency update
	# helm dependency update repackages both vendored subcharts into
	# charts/*.tgz, right next to the source directories they came from. Helm
	# then finds two charts of the same name and which one wins is not stable,
	# so a stale archive silently installs an older chart. The unpacked
	# directories are authoritative here — drop the archives.
	rm -f charts/*.tgz

lint: deps
	helm lint .

template: deps
	helm template $(RELEASE) . -n $(NAMESPACE) -f $(VALUES) \
	  --set cluster.clickhouse.defaultUser.password=changeme

package: deps lint
	helm package . --destination dist/

## Two-step install avoids CRD race on first apply.
## Both releases share NAMESPACE: operator.rbac.namespaceScoped=true scopes the
## operator's Role to its own namespace, so the cluster must live there too.
install-operator:
	helm upgrade --install $(RELEASE)-operator . -n $(NAMESPACE) --create-namespace \
	  -f $(VALUES) --set cluster.enabled=false

install-cluster:
	helm upgrade --install $(RELEASE) . -n $(NAMESPACE) --create-namespace \
	  -f $(VALUES) --set operator.enabled=false \
	  --set cluster.clickhouse.defaultUser.password='$(PASSWORD)'

install: deps
	@test -n "$(PASSWORD)" || (echo 'Set PASSWORD=... for default user'; exit 1)
	helm upgrade --install $(RELEASE) . -n $(NAMESPACE) --create-namespace \
	  -f $(VALUES) --set cluster.clickhouse.defaultUser.password='$(PASSWORD)'

uninstall:
	helm uninstall $(RELEASE) -n $(NAMESPACE) || true
	helm uninstall $(RELEASE)-operator -n $(NAMESPACE) || true
