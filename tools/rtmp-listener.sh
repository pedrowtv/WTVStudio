#!/bin/zsh
# Ouvinte RTMP local para testes (docs/AMBIENTE.md): grava o que receber e mostra o ffprobe.
# Uso: tools/rtmp-listener.sh [porta] [segundos] [ficheiro]
set -eu
PORT=${1:-19350}
SECS=${2:-10}
OUT=${3:-/tmp/wtv-rtmp-recv.flv}
echo "A escutar rtmp://127.0.0.1:${PORT}/live/test durante ${SECS}s → ${OUT}"
ffmpeg -hide_banner -loglevel warning -listen 1 -i "rtmp://127.0.0.1:${PORT}/live/test" -c copy -t "${SECS}" -y "${OUT}"
ffprobe -hide_banner -show_entries stream=codec_name,width,height,r_frame_rate,sample_rate -show_entries format=duration -of compact "${OUT}"
