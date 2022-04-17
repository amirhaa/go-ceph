CI_IMAGE_NAME = go-ceph-ci
CONTAINER_CMD ?=
CONTAINER_OPTS := --security-opt $(shell grep -q selinux /sys/kernel/security/lsm 2>/dev/null && echo "label=disable" || echo "apparmor:unconfined")
CONTAINER_BUILD_OPTS :=
CONTAINER_CONFIG_DIR := testing/containers/ceph
VOLUME_FLAGS :=
CEPH_VERSION := octopus
RESULTS_DIR :=
CHECK_GOFMT_FLAGS := -e -s -l
IMPLEMENTS_OPTS :=
BUILD_TAGS := $(CEPH_VERSION)

ifeq ($(CONTAINER_CMD),)
	CONTAINER_CMD:=$(shell docker version >/dev/null 2>&1 && echo docker)
endif
ifeq ($(CONTAINER_CMD),)
	CONTAINER_CMD:=$(shell podman version >/dev/null 2>&1 && echo podman)
endif

ifeq ($(CEPH_VERSION),nautilus)
	CEPH_TAG := v14
endif
ifeq ($(CEPH_VERSION),octopus)
	CEPH_TAG := v15
endif
ifeq ($(CEPH_VERSION),pacific)
	CEPH_TAG := v16
endif

GO_CMD:=go
GOFMT_CMD:=gofmt

# the full name of the marker file including the ceph version
BUILDFILE=.build.$(CEPH_VERSION)

# files marking daemon containers supporting the tests
TEST_CTR_A=.run.test_ceph_a
TEST_CTR_B=.run.test_ceph_b
TEST_CTR_NET=.run.test_ceph_net

# the name of the image plus ceph version as tag
CI_IMAGE_TAG=$(CI_IMAGE_NAME):$(CEPH_VERSION)

ifneq ($(USE_PTRGUARD),)
	CONTAINER_OPTS += -e USE_PTRGUARD=true
	BUILD_TAGS := $(BUILD_TAGS),ptrguard
endif

ifneq ($(NO_PREVIEW),)
	CONTAINER_OPTS += -e NO_PREVIEW=true
else
	BUILD_TAGS := $(BUILD_TAGS),ceph_preview
endif

ifneq ($(USE_CACHE),)
	GOCACHE_VOLUME := -v test_ceph_go_cache:/go
endif

SELINUX := $(shell getenforce 2>/dev/null)
ifeq ($(SELINUX),Enforcing)
	VOLUME_FLAGS = :z
endif

ifdef RESULTS_DIR
	RESULTS_VOLUME := -v $(RESULTS_DIR):/results$(VOLUME_FLAGS)
endif

ifneq ($(USE_GOCO),)
	GO_CMD:=$(CONTAINER_CMD) run $(CONTAINER_OPTS) --rm $(GOCACHE_VOLUME) -v $(CURDIR):/go/src/github.com/amirhaa/go-ceph$(VOLUME_FLAGS) --entrypoint $(GO_CMD) $(CI_IMAGE_TAG)
	GOFMT_CMD:=$(CONTAINER_CMD) run $(CONTAINER_OPTS) --rm $(GOCACHE_VOLUME) -v $(CURDIR):/go/src/github.com/amirhaa/go-ceph$(VOLUME_FLAGS) --entrypoint $(GOFMT_CMD) $(CI_IMAGE_TAG)
endif

build:
	$(GO_CMD) build -v -tags $(BUILD_TAGS) $(shell $(GO_CMD) list ./... | grep -v /contrib)
fmt:
	$(GO_CMD) fmt ./...
test:
	$(GO_CMD) test -v -tags $(BUILD_TAGS) ./...

.PHONY: test-docker test-container test-multi-container
test-docker: test-container
test-container: $(BUILDFILE) $(RESULTS_DIR)
	$(CONTAINER_CMD) run $(CONTAINER_OPTS) --rm --hostname test_ceph_aio \
		-v $(CURDIR):/go/src/github.com/amirhaa/go-ceph$(VOLUME_FLAGS) $(RESULTS_VOLUME) $(GOCACHE_VOLUME) \
		$(CI_IMAGE_TAG) $(ENTRYPOINT_ARGS)
test-multi-container: $(BUILDFILE) $(RESULTS_DIR)
	-$(MAKE) test-containers-kill
	-$(MAKE) test-containers-rm-volumes
	-$(MAKE) test-containers-rm-network
	$(MAKE) test-containers-test
	$(MAKE) test-containers-kill
	$(MAKE) test-containers-rm-volumes
	$(MAKE) test-containers-rm-network

# The test-containers-* cleanup rules:
.PHONY: test-containers-clean \
	test-containers-kill \
	test-containers-rm-volumes \
	test-containers-rm-network

test-containers-clean: test-containers-kill
	-$(MAKE) test-containers-rm-volumes
	-$(MAKE) test-containers-rm-network

test-containers-kill:
	-$(CONTAINER_CMD) kill test_ceph_a || $(CONTAINER_CMD) rm test_ceph_a
	-$(CONTAINER_CMD) kill test_ceph_b || $(CONTAINER_CMD) rm test_ceph_b
	$(RM) $(TEST_CTR_A) $(TEST_CTR_B)
	sleep 0.3
# sometimes the container runtime fails to remove things immediately after
# killing the containers. The short sleep helps avoid hitting that condition.

test-containers-rm-volumes:
	$(CONTAINER_CMD) volume remove test_ceph_a_data test_ceph_b_data

test-containers-rm-network:
	$(CONTAINER_CMD) network rm test_ceph_net
	$(RM) $(TEST_CTR_NET)

# Thest test-containers-* setup rules:
.PHONY: test-containers-network \
	test-containers-test_ceph_a \
	test-containers-test_ceph_b \
	test-containers-test

test-containers-network: $(TEST_CTR_NET)
$(TEST_CTR_NET):
	($(CONTAINER_CMD) network ls -q | grep -q test_ceph_net) \
		|| $(CONTAINER_CMD) network create test_ceph_net
	@echo "test_ceph_net" > $(TEST_CTR_NET)

test-containers-test_ceph_a: $(TEST_CTR_A)
$(TEST_CTR_A): $(TEST_CTR_NET) $(BUILDFILE)
	$(CONTAINER_CMD) run $(CONTAINER_OPTS) \
		--cidfile=$(TEST_CTR_A) --rm -d --name test_ceph_a \
		 --hostname test_ceph_a \
		--net test_ceph_net \
		-v test_ceph_a_data:/tmp/ceph $(CI_IMAGE_TAG) \
		--test-run=NONE --pause

test-containers-test_ceph_b: $(TEST_CTR_B)
$(TEST_CTR_B): $(TEST_CTR_NET) $(BUILDFILE)
	$(CONTAINER_CMD) run $(CONTAINER_OPTS) \
		--cidfile=$(TEST_CTR_B) --rm -d --name test_ceph_b \
		--hostname test_ceph_b \
		--net test_ceph_net \
		-v test_ceph_b_data:/tmp/ceph $(CI_IMAGE_TAG) \
		--test-run=NONE --pause

test-containers-test: $(BUILDFILE) $(TEST_CTR_A) $(TEST_CTR_B)
	$(CONTAINER_CMD) run $(CONTAINER_OPTS) --rm \
		--net test_ceph_net \
		-v test_ceph_a_data:/ceph_a \
		-v test_ceph_b_data:/ceph_b \
		-v $(CURDIR):/go/src/github.com/amirhaa/go-ceph$(VOLUME_FLAGS) \
		$(RESULTS_VOLUME) $(GOCACHE_VOLUME) \
		$(CI_IMAGE_TAG) \
		--wait-for=/ceph_a/.ready:/ceph_b/.ready \
		--mirror-state=/ceph_b/.mstate \
		--ceph-conf=/ceph_a/ceph.conf \
		--mirror=/ceph_b/ceph.conf $(ENTRYPOINT_ARGS)

ifdef RESULTS_DIR
$(RESULTS_DIR):
	mkdir -p $(RESULTS_DIR)
endif

.PHONY: ci-image
ci-image: $(BUILDFILE)
$(BUILDFILE): $(CONTAINER_CONFIG_DIR)/Dockerfile entrypoint.sh micro-osd.sh
	$(CONTAINER_CMD) build \
		--build-arg GO_CEPH_VERSION=$(CEPH_VERSION) \
		--build-arg CEPH_TAG=$(CEPH_TAG) \
		$(CONTAINER_BUILD_OPTS) \
		-t $(CI_IMAGE_TAG) \
		-f $(CONTAINER_CONFIG_DIR)/Dockerfile .
	@$(CONTAINER_CMD) inspect -f '{{.Id}}' $(CI_IMAGE_TAG) > $(BUILDFILE)
	echo $(CEPH_VERSION) >> $(BUILDFILE)

check: check-revive check-format

check-format:
	! $(GOFMT_CMD) $(CHECK_GOFMT_FLAGS) . | sed 's,^,formatting error: ,' | grep 'go$$'

check-revive:
	# Configure project's revive checks using .revive.toml
	# See: https://github.com/mgechev/revive
	revive -config .revive.toml $$(find . -name '*.go')

# Do a quick compile only check of the tests and impliclity the
# library code as well.
test-binaries: \
	cephfs.test \
	cephfs/admin.test \
	common/admin/manager.test \
	common/admin/nfs.test \
	internal/callbacks.test \
	internal/commands.test \
	internal/cutil.test \
	internal/errutil.test \
	internal/retry.test \
	rados.test \
	rbd.test \
	rbd/admin.test
test-bins: test-binaries

%.test: % force_go_build
	$(GO_CMD) test -c -tags $(BUILD_TAGS) ./$<

implements:
	cd contrib/implements && $(GO_CMD) build -o ../../implements

check-implements: implements
	./implements $(IMPLEMENTS_OPTS) cephfs rados rbd

clean-implements:
	$(RM) ./implements


api-check: implements-json
	./contrib/apiage.py

api-update: implements-json
	./contrib/apiage.py --mode=update \
		--current-tag="$$(git describe --tags --abbrev=0)"

api-doc:
	./contrib/apiage.py --mode=write-doc

ifeq ($(RESULTS_DIR),)
IMPLEMENTS_DIR:=$(PWD)/_results
else
IMPLEMENTS_DIR:=$(RESULTS_DIR)
endif

implements-json: $(BUILDFILE)
	$(MAKE) RESULTS_DIR="$(IMPLEMENTS_DIR)" ENTRYPOINT_ARGS="--test-run=IMPLEMENTS --micro-osd=/bin/true $(ENTRYPOINT_ARGS)" test-container

# force_go_build is phony and builds nothing, can be used for forcing
# go toolchain commands to always run
.PHONY: build fmt test test-docker check test-binaries test-bins force_go_build check-implements clean-implements api-check api-update api-doc implements-json
