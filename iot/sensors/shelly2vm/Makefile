BINARY := shelly2vm
HOST   ?= margiehamilton

.PHONY: build check deploy clean

build:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o $(BINARY) .

check:
	gofmt -l . | tee /dev/stderr | wc -l | grep -qx 0
	go vet ./...

deploy: build
	scp -q $(BINARY) $(HOST):/tmp/$(BINARY).new

clean:
	rm -f $(BINARY)
