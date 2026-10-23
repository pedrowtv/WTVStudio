#!/bin/zsh
# Corre o ffplayout (playout 24/7 em Rust) a enviar MPEG-TS por UDP para o WTV Studio (fonte "ffplayout…" nas Fontes).
# Pré-requisitos (docs/INSTALACAO.md): ffplayout compilado em ~/.cache/wtv-ffplayout e canal 1 inicializado.
# Uso: tools/ffplayout-wtv.sh folder <pasta de clips>      → toca a pasta em ciclo
#      tools/ffplayout-wtv.sh playlist                     → grelha diária em data/playlists/AAAA/MM/AAAA-MM-DD.json
set -eu
FP="${FFPLAYOUT_BIN:-$HOME/.cache/wtv-ffplayout/ffplayout/target/release/ffplayout}"
D="${FFPLAYOUT_DATA:-$HOME/.cache/wtv-ffplayout/data}"
MODE="${1:-playlist}"
cd "$D"
if [[ "$MODE" == "folder" ]]; then
  exec "$FP" --db "$D/ffplayout.db" --channel 1 --foreground -o stream --folder "${2:-$D/storage}" --log-to-console
else
  exec "$FP" --db "$D/ffplayout.db" --channel 1 --foreground -o stream --log-to-console
fi
