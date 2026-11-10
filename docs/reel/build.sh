#!/bin/zsh
# Полная сборка рилса: голос → видео → звук → склейка.
# Запуск из корня репозитория: zsh docs/reel/build.sh [classic|goth ...]   (без аргументов — только classic)
# Переозвучить всё: RETTS=1 zsh docs/reel/build.sh;  одну реплику: docs/reel/.venv/bin/python docs/reel/tts.py goth s2
set -e
cd "$(dirname "$0")"
mux() {  # видео + звук, громкость под соцсети (−14 LUFS)
  ffmpeg -y -loglevel error -i "video-$1.mp4" -i "$2" -c:v copy -af loudnorm=I=-14:TP=-1.5:LRA=11 \
    -ar 48000 -c:a aac -b:a 192k -shortest "$3"
}
variants=("$@"); (( $#variants )) || variants=(classic)  # готика отложена: zsh build.sh goth
for v in $variants; do
  # озвучка долгая (~10 мин на вариант): заново только если её нет или задан RETTS=1
  [[ -f voice-$v.json && -z $RETTS ]] || .venv-qwen/bin/python tts.py "$v"
  VARIANT=$v node render.mjs
  .venv/bin/python mix.py "$v"
  mux "$v" "mix-$v.wav" "yinyang-reel-$v.mp4"
  [[ $v == classic ]] && mux classic voice_sfx-classic.wav yinyang-reel-classic-no-music.mp4
  echo "готово: docs/reel/yinyang-reel-$v.mp4"
done
