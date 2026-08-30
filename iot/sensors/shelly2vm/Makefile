BINARY := shelly2vm
HOST   ?=

.PHONY: build check deploy clean

build:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o $(BINARY) .

check:
	gofmt -l . | tee /dev/stderr | wc -l | grep -qx 0
	go vet ./...

deploy: build
	@test -n "$(HOST)" || { echo "set HOST=<ssh target>" >&2; exit 1; }
	scp -q $(BINARY) $(HOST):/tmp/$(BINARY).new

clean:
	rm -f $(BINARY)
