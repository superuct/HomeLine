#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root/nas/nas/webrtc-voice"
go mod verify
go test ./...
python3 -m unittest test_calls test_sms_archive test_sms_retention
cd "$root/nas/deploy"
python3 -m unittest discover -p 'test_*.py'
