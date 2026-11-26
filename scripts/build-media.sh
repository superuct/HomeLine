#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$root/nas/bin"
cd "$root/nas/nas/webrtc-voice"
go mod verify
go test ./...
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -o "$root/nas/bin/homeline-media" .
