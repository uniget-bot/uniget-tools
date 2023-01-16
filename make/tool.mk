.SECONDARY: $(addsuffix /history.json,$(ALL_TOOLS))
$(addsuffix /history.json,$(ALL_TOOLS)):$(TOOLS_DIR)/%/history.json: $(HELPER)/var/lib/docker-setup/manifests/jq.json
	@set -o errexit; \
	git log --author=renovate* --pretty="format:%cs %s" -- $(TOOLS_DIR)/$*/manifest.yaml \
	| jq --raw-input --slurp 'split("\n")' >$@

$(addsuffix /manifest.json,$(ALL_TOOLS)):$(TOOLS_DIR)/%/manifest.json: $(HELPER)/var/lib/docker-setup/manifests/jq.json $(HELPER)/var/lib/docker-setup/manifests/yq.json $(TOOLS_DIR)/%/manifest.yaml $(TOOLS_DIR)/%/history.json ; $(info $(M) Creating manifest for $*...)
	@set -o errexit; \
	yq --output-format json eval '{"tools":[.]}' $(TOOLS_DIR)/$*/manifest.yaml \
	| jq --slurp '.[0].tools[0].history = .[1] | .[0]' - $(TOOLS_DIR)/$*/history.json >$(TOOLS_DIR)/$*/manifest.json

$(addsuffix /Dockerfile,$(ALL_TOOLS)):$(TOOLS_DIR)/%/Dockerfile: $(TOOLS_DIR)/%/Dockerfile.template $(TOOLS_DIR)/Dockerfile.tail ; $(info $(M) Creating $@...)
	@set -o errexit; \
	cat $@.template >$@; \
	echo >>$@; \
	echo >>$@; \
	if test -f $(TOOLS_DIR)/$*/post_install.sh; then echo 'COPY post_install.sh $${prefix}$${docker_setup_post_install}/$${name}.sh' >>$@; fi; \
	cat $(TOOLS_DIR)/Dockerfile.tail >>$@

.PHONY:
install: push sign attest

.PHONY:
base: info ; $(info $(M) Building base image $(REGISTRY)/$(REPOSITORY_PREFIX)base:$(DOCKER_TAG)...)
	@set -o errexit; \
	if ! docker build @base \
			--build-arg prefix_override=$(PREFIX) \
			--build-arg target_override=$(TARGET) \
			--cache-from $(REGISTRY)/$(REPOSITORY_PREFIX)base:$(DOCKER_TAG) \
			--tag $(REGISTRY)/$(REPOSITORY_PREFIX)base:$(DOCKER_TAG) \
			--progress plain \
			>@base/build.log 2>&1; then \
		cat @base/build.log; \
		exit 1; \
	fi

.PHONY:
$(ALL_TOOLS_RAW):%: $(HELPER)/var/lib/docker-setup/manifests/jq.json base $(TOOLS_DIR)/%/manifest.json $(TOOLS_DIR)/%/Dockerfile ; $(info $(M) Building image $(REGISTRY)/$(REPOSITORY_PREFIX)$*:$(DOCKER_TAG)...)
	@set -o errexit; \
	TOOL_VERSION="$$(jq --raw-output '.tools[].version' tools/$*/manifest.json)"; \
	DEPS="$$(jq --raw-output '.tools[] | select(.dependencies != null) |.dependencies[]' tools/$*/manifest.json | paste -sd,)"; \
	TAGS="$$(jq --raw-output '.tools[] | select(.tags != null) |.tags[]' tools/$*/manifest.json | paste -sd,)"; \
	echo "Name:         $*"; \
	echo "Version:      $${TOOL_VERSION}"; \
	echo "Dependencies: $${DEPS}"; \
	if ! docker build $(TOOLS_DIR)/$@ \
			--build-arg branch=$(DOCKER_TAG) \
			--build-arg ref=$(DOCKER_TAG) \
			--build-arg name=$* \
			--build-arg version=$${TOOL_VERSION} \
			--build-arg deps=$${DEPS} \
			--build-arg tags=$${TAGS} \
			--cache-from $(REGISTRY)/$(REPOSITORY_PREFIX)$*:$(DOCKER_TAG) \
			--tag $(REGISTRY)/$(REPOSITORY_PREFIX)$*:$(DOCKER_TAG) \
			--progress plain \
			>$(TOOLS_DIR)/$@/build.log 2>&1; then \
		cat $(TOOLS_DIR)/$@/build.log; \
		exit 1; \
	fi

$(addsuffix --deep,$(ALL_TOOLS_RAW)):%--deep: info metadata.json
	@set -o errexit; \
	DEPS="$$(./docker-setup --tools="$*" dependencies)"; \
	echo "Making deps: $${DEPS}."; \
	make $${DEPS}

.PHONY:
push: $(addsuffix --push,$(TOOLS_RAW)) metadata.json--push

.PHONY:
$(addsuffix --push,$(ALL_TOOLS_RAW)):%--push: % ; $(info $(M) Pushing image for $*...)
	@docker push $(REGISTRY)/$(REPOSITORY_PREFIX)$*:$(DOCKER_TAG)

.PHONY:
$(addsuffix --inspect,$(ALL_TOOLS_RAW)):%--inspect: $(HELPER)/var/lib/docker-setup/manifests/regclient.json ; $(info $(M) Inspecting image for $*...)
	@regctl manifest get $(REGISTRY)/$(REPOSITORY_PREFIX)$*:$(DOCKER_TAG)

.PHONY:
$(addsuffix --install,$(ALL_TOOLS_RAW)):%--install: %--push %--sign %--attest

.PHONY:
$(addsuffix --debug,$(ALL_TOOLS_RAW)):%--debug: $(HELPER)/var/lib/docker-setup/manifests/jq.json $(TOOLS_DIR)/%/manifest.json $(TOOLS_DIR)/%/Dockerfile ; $(info $(M) Debugging image for $*...)
	@set -o errexit; \
	TOOL_VERSION="$$(jq --raw-output '.tools[].version' $(TOOLS_DIR)/$*/manifest.json)"; \
	DEPS="$$(jq --raw-output '.tools[] | select(.dependencies != null) |.dependencies[]' tools/$*/manifest.json | paste -sd,)"; \
	TAGS="$$(jq --raw-output '.tools[] | select(.tags != null) |.tags[]' tools/$*/manifest.json | paste -sd,)"; \
	echo "Name:         $*"; \
	echo "Version:      $${TOOL_VERSION}"; \
	echo "Dependencies: $${DEPS}"; \
	docker buildx build $(TOOLS_DIR)/$* \
		--build-arg branch=$(DOCKER_TAG) \
		--build-arg ref=$(DOCKER_TAG) \
		--build-arg name=$* \
		--build-arg version=$${TOOL_VERSION} \
		--build-arg deps=$${DEPS} \
		--build-arg tags=$${TAGS} \
		--cache-from $(REGISTRY)/$(REPOSITORY_PREFIX)$*:$(DOCKER_TAG) \
		--tag $(REGISTRY)/$(REPOSITORY_PREFIX)$*:$(DOCKER_TAG) \
		--target prepare \
		--load \
		--progress plain && \
	docker container run \
		--interactive \
		--tty \
		--privileged \
		--env name=$* \
		--env version=$${TOOL_VERSION} \
		--rm \
		$(REGISTRY)/$(REPOSITORY_PREFIX)$*:$(DOCKER_TAG) \
			bash

.PHONY:
$(addsuffix --test,$(ALL_TOOLS_RAW)):%--test: % ; $(info $(M) Testing $*...)
	@set -o errexit; \
	if ! test -f "$(TOOLS_DIR)/$*/test.sh"; then \
		echo "Nothing to test."; \
		exit; \
	fi; \
	./docker-setup --tools=$* build test-$*; \
	bash $(TOOLS_DIR)/$*/test.sh test-$*

.PHONY:
debug: base
	@docker container run \
		--interactive \
		--tty \
		--privileged \
		--rm \
		$(REGISTRY)/$(REPOSITORY_PREFIX)base:$(DOCKER_TAG) \
			bash
