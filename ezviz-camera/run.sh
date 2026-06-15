#!/usr/bin/with-contenv bashio

set +e

# ============================================
# CONFIG
# ============================================
EMAIL=$(bashio::config 'email')
PASSWORD=$(bashio::config 'password')
SERIAL=$(bashio::config 'serial')
REGION=$(bashio::config 'region')
HLS_TIME=$(bashio::config 'hls_time')
HLS_LIST_SIZE=$(bashio::config 'hls_list_size')
ON_DEMAND=$(bashio::config 'on_demand')
IDLE_TIMEOUT=$(bashio::config 'idle_timeout')

# ============================================
# PREP
# ============================================
mkdir -p /share/ezviz_hls

bashio::log.info "Starting EZVIZ Camera HLS Stream..."
bashio::log.info "Serial: ${SERIAL}"
bashio::log.info "Region: ${REGION}"
bashio::log.info "On-demand mode: ${ON_DEMAND}"

# IMPORTANT: DO NOT pre-create m3u8 (prevents race conditions)
rm -f /share/ezviz_hls/*.ts /share/ezviz_hls/*.m3u8

# ============================================
# HTTP SERVER
# ============================================
start_http_server() {
    python3 /app/http_server.py \
        --port 8080 \
        --directory /share/ezviz_hls &
    HTTP_PID=$!
    bashio::log.info "HTTP server started (PID: ${HTTP_PID})"
}

check_http_server() {
    if ! kill -0 "$HTTP_PID" 2>/dev/null; then
        bashio::log.warning "HTTP server died, restarting..."
        start_http_server
    fi
}

# small warmup to avoid early 404 spam
sleep 2
start_http_server

# ============================================
# STREAM LOOP
# ============================================
RESTART_COUNT=0

while true; do
    RESTART_COUNT=$((RESTART_COUNT + 1))
    bashio::log.info "[${RESTART_COUNT}] Starting EZVIZ stream..."

    # FIX: stable session (NO rotating IDs)
    SESSION_ID="live"

    # ============================================
    # PIPE WRAPPER (CRITICAL FIX)
    # prevents ffmpeg from dying on 0-byte drops
    # ============================================
    (
        while true; do
            python3 -u /app/stream_to_pipe.py \
                --email "${EMAIL}" \
                --password "${PASSWORD}" \
                --serial "${SERIAL}" \
                --region "${REGION}" || true

            bashio::log.warning "EZVIZ pipe dropped → reconnecting in 2s..."
            sleep 2
        done
    ) | ffmpeg -re -i pipe:0 \
        -c:v libx264 \
        -preset ultrafast \
        -tune zerolatency \
        -crf 23 \
        -g 30 \
        -keyint_min 30 \
        -sc_threshold 0 \
        -f hls \
        -hls_time "${HLS_TIME}" \
        -hls_list_size "${HLS_LIST_SIZE}" \
        -hls_flags append_list+independent_segments+temp_file+omit_endlist \
        -hls_segment_filename "/share/ezviz_hls/seg_%03d.ts" \
        /share/ezviz_hls/stream.m3u8 2>&1 || true

    bashio::log.warning "FFmpeg exited → restarting stream..."

    # cleanup only OLD segments (safe)
    ls -1t /share/ezviz_hls/*.ts 2>/dev/null | tail -n +50 | xargs -r rm -f

    check_http_server

    sleep 1
done
