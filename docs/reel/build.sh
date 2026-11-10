#!/bin/zsh
# Полная сборка рилса: голос → видео → звук → склейка.
# Запуск из корня репозитория: zsh docs/reel/build.sh [голос: dmitri|denis|irina]
set -e
cd "$(dirname "$0")"
.venv/bin/python tts.py "${1:-dmitri}"
node render.mjs
.venv/bin/python mix.py
ffmpeg -y -loglevel error -i video-only.mp4 -i mix.wav -c:v copy -af loudnorm=I=-14:TP=-1.5:LRA=11 -ar 48000 -c:a aac -b:a 192k -shortest yinyang-reel.mp4
ffmpeg -y -loglevel error -i video-only.mp4 -i voice_sfx.wav -c:v copy -af loudnorm=I=-14:TP=-1.5:LRA=11 -ar 48000 -c:a aac -b:a 192k -shortest yinyang-reel-no-music.mp4
echo "готово: docs/reel/yinyang-reel.mp4 (с музыкой) и yinyang-reel-no-music.mp4 (голос + эффекты)"
