#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
: "${HOMELINE_CONFIG:?Set HOMELINE_CONFIG to the private TLS and configuration directory}"
: "${HOMELINE_STATE:?Set HOMELINE_STATE to the private data directory}"
: "${AT_DEVICE:?Set AT_DEVICE to the EC20 AT port}"
: "${PCM_DEVICE:?Set PCM_DEVICE to the EC20 PCM port}"
case "$HOMELINE_CONFIG:$HOMELINE_STATE" in
    /*:/*) ;;
    *) echo 'HOMELINE_CONFIG and HOMELINE_STATE must be absolute paths' >&2; exit 2 ;;
esac
umask 077
mkdir -p "$HOMELINE_STATE/work"
cd "$HOMELINE_STATE/work"
case "${1:-start}" in
    restore)
        exec python3 "$root/nas/webrtc-voice/radio.py" --restore --at "$AT_DEVICE"
        ;;
    start)
        if [ -e active-radio ]; then
            python3 "$root/nas/webrtc-voice/radio.py" --restore --at "$AT_DEVICE"
        fi
        case "${HOMELINE_MODE:-direct}" in
            direct) set -- --listen "${TLS_BIND:-0.0.0.0}" --port "${TLS_PORT:-18443}"
                    ice_bind=${ICE_BIND:-0.0.0.0}; public_ip=${ICE_PUBLIC_IP:-} ;;
            sakurafrp) set -- --listen 127.0.0.1 --port "${FRP_ORIGIN_PORT:-18086}" --http-only
                       ice_bind=127.0.0.1; public_ip= ;;
            *) echo 'HOMELINE_MODE must be direct or sakurafrp' >&2; exit 2 ;;
        esac
        exec python3 -u "$root/nas/webrtc-voice/radio.py" "$@" \
            --ice "$ice_bind:${ICE_PORT:-20119}" --public-ip "$public_ip" \
            --at "$AT_DEVICE" --pcm "$PCM_DEVICE" --media "${MEDIA_BIN:-$root/bin/homeline-media}" \
            --sms-port "${SMS_LOOPBACK_PORT:-14675}" --work "$HOMELINE_STATE/work"
        ;;
    *) exit 2 ;;
esac
