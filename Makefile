GOPATH ?= $(shell go env GOPATH)

# Ensure GOPATH is set before running build process.
ifeq "$(GOPATH)" ""
  $(error Please set the environment variable GOPATH before running `make`)
endif

CURDIR := $(shell pwd)
path_to_add := $(addsuffix /bin,$(subst :,/bin:,$(GOPATH)))
export PATH := $(path_to_add):$(PATH)

GO        := go
GOBUILD   := CGO_ENABLED=0 $(GO) build $(BUILD_FLAG)
GOTEST    := CGO_ENABLED=1 $(GO) test -p 3
OVERALLS  := CGO_ENABLED=1 overalls
GOVERALLS := goveralls

ARCH      := "`uname -s`"
LINUX     := "Linux"
MAC       := "Darwin"
PACKAGES  := $$(go list ./...| grep -vE "vendor")
FILES     := $$(find . -name "*.go" | grep -vE "vendor")
TOPDIRS   := $$(ls -d */ | grep -vE "vendor")

GOFAIL_ENABLE  := $$(find $$PWD/ -type d | grep -vE "(\.git|vendor)" | xargs gofail enable)
GOFAIL_DISABLE := $$(find $$PWD/ -type d | grep -vE "(\.git|vendor)" | xargs gofail disable)

LDFLAGS += -X "github.com/pingcap/tidb/mysql.TiDBReleaseVersion=$(shell git describe --tags --dirty)"
LDFLAGS += -X "github.com/pingcap/tidb/util/printer.TiDBBuildTS=$(shell date -u '+%Y-%m-%d %I:%M:%S')"
LDFLAGS += -X "github.com/pingcap/tidb/util/printer.TiDBGitHash=$(shell git rev-parse HEAD)"
LDFLAGS += -X "github.com/pingcap/tidb/util/printer.TiDBGitBranch=$(shell git rev-parse --abbrev-ref HEAD)"
LDFLAGS += -X "github.com/pingcap/tidb/util/printer.GoVersion=$(shell go version)"

TARGET = ""

.PHONY: all build update parser clean todo test gotest interpreter server dev benchkv benchraw check parserlib checklist

default: server buildsucc

buildsucc:
	@echo Build TiDB Server successfully!

all: dev server benchkv

dev: checklist parserlib test check

build:
	$(GOBUILD)

goyacc:
	$(GOBUILD) -o bin/goyacc parser/goyacc/main.go

parser: goyacc
	bin/goyacc -o /dev/null parser/parser.y
	bin/goyacc -o parser/parser.go parser/parser.y 2>&1 | egrep "(shift|reduce)/reduce" | awk '{print} END {if (NR > 0) {print "Find conflict in parser.y. Please check y.output for more information."; exit 1;}}'
	rm -f y.output

	@if [ $(ARCH) = $(LINUX) ]; \
	then \
		sed -i -e 's|//line.*||' -e 's/yyEofCode/yyEOFCode/' parser/parser.go; \
	elif [ $(ARCH) = $(MAC) ]; \
	then \
		/usr/bin/sed -i "" 's|//line.*||' parser/parser.go; \
		/usr/bin/sed -i "" 's/yyEofCode/yyEOFCode/' parser/parser.go; \
	fi

	@awk 'BEGIN{print "// Code generated by goyacc"} {print $0}' parser/parser.go > tmp_parser.go && mv tmp_parser.go parser/parser.go;

parserlib: parser/parser.go

parser/parser.go: parser/parser.y
	make parser

check: fmt errcheck lint vet

fmt:
	@echo "gofmt (simplify)"
	@ gofmt -s -l -w $(FILES) 2>&1 | grep -v "vendor|parser/parser.go" | awk '{print} END{if(NR>0) {exit 1}}'

goword:
	go get github.com/chzchzchz/goword
	@echo "goword"
	@ goword $(FILES) | awk '{print} END{if(NR>0) {exit 1}}'

errcheck:
	go get github.com/kisielk/errcheck
	@echo "errcheck"
	@ GOPATH=$(GOPATH) errcheck -blank $(PACKAGES) | grep -v "_test\.go" | awk '{print} END{if(NR>0) {exit 1}}'

lint:
	mkdir -p $(GOPATH)/src/golang.org/x 
	git clone --depth=1 https://github.com/golang/lint.git $(GOPATH)/src/golang.org/x/lint
	go get -u golang.org/x/lint/golint
	@echo "golint"
	@ golint -set_exit_status $(PACKAGES)

vet:
	@echo "vet"
	@ go tool vet -all -shadow $(TOPDIRS) 2>&1 | awk '{print} END{if(NR>0) {exit 1}}'

clean:
	$(GO) clean -i ./...
	rm -rf *.out

todo:
	@grep -n ^[[:space:]]*_[[:space:]]*=[[:space:]][[:alpha:]][[:alnum:]]* */*.go parser/parser.y || true
	@grep -n TODO */*.go parser/parser.y || true
	@grep -n BUG */*.go parser/parser.y || true
	@grep -n println */*.go parser/parser.y || true

test: checklist gotest

gotest: parserlib
	go get github.com/coreos/gofail
	@$(GOFAIL_ENABLE)
ifeq ("$(TRAVIS_COVERAGE)", "1")
	@echo "Running in TRAVIS_COVERAGE mode."
	@export log_level=error; \
	go get github.com/go-playground/overalls
	go get github.com/mattn/goveralls
	$(OVERALLS) -project=github.com/pingcap/tidb -covermode=count -ignore='.git,_vendor' || { $(GOFAIL_DISABLE); exit 1; }
	$(GOVERALLS) -service=travis-ci -coverprofile=overalls.coverprofile || { $(GOFAIL_DISABLE); exit 1; }
else
	@echo "Running in native mode."
	@export log_level=error; \
	$(GOTEST) -cover $(PACKAGES) || { $(GOFAIL_DISABLE); exit 1; }
endif
	@$(GOFAIL_DISABLE)

race: parserlib
	go get github.com/coreos/gofail
	@$(GOFAIL_ENABLE)
	@export log_level=debug; \
	$(GOTEST) -race $(PACKAGES)
	@$(GOFAIL_DISABLE)

leak: parserlib
	go get github.com/coreos/gofail
	@$(GOFAIL_ENABLE)
	@export log_level=debug; \
	$(GOTEST) -tags leak $(PACKAGES)
	@$(GOFAIL_DISABLE)

tikv_integration_test: parserlib
	go get github.com/coreos/gofail
	@$(GOFAIL_ENABLE)
	$(GOTEST) ./store/tikv/. -with-tikv=true
	@$(GOFAIL_DISABLE)

RACE_FLAG = 
ifeq ("$(WITH_RACE)", "1")
	RACE_FLAG = -race
	GOBUILD   = GOPATH=$(GOPATH) CGO_ENABLED=1 $(GO) build
endif

server: parserlib
ifeq ($(TARGET), "")
	$(GOBUILD) $(RACE_FLAG) -ldflags '$(LDFLAGS)' -o bin/tidb-server tidb-server/main.go
else
	$(GOBUILD) $(RACE_FLAG) -ldflags '$(LDFLAGS)' -o '$(TARGET)' tidb-server/main.go
endif

benchkv:
	$(GOBUILD) -ldflags '$(LDFLAGS)' -o bin/benchkv cmd/benchkv/main.go

benchraw:
	$(GOBUILD) -ldflags '$(LDFLAGS)' -o bin/benchraw cmd/benchraw/main.go

benchdb:
	$(GOBUILD) -ldflags '$(LDFLAGS)' -o bin/benchdb cmd/benchdb/main.go
importer:
	$(GOBUILD) -ldflags '$(LDFLAGS)' -o bin/importer ./cmd/importer

update:
	which dep 2>/dev/null || go get -u github.com/golang/dep/cmd/dep
ifdef PKG
	dep ensure -add ${PKG}
else
	dep ensure -update
endif
	@echo "removing test files"
	dep prune
	bash ./hack/clean_vendor.sh

checklist:
	cat checklist.md

gofail-enable:
# Converting gofail failpoints...
	@$(GOFAIL_ENABLE)

gofail-disable:
# Restoring gofail failpoints...
	@$(GOFAIL_DISABLE)
