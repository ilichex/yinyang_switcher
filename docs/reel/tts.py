# Озвучка рилса нейросетью Piper (офлайн, модель — только веса ONNX, без кода).
# Каждая реплика — отдельный wav; длительности пишем в voice.json,
# по ним reel.html растягивает сцены под голос.
# Запуск: .venv/bin/python tts.py [голос]   голоса: denis dmitri irina
import json, os, sys, wave
from piper import PiperVoice, SynthesisConfig

LINES = {
    's1': 'Опять напечатал абракадабру не на той раскладке?',
    's2': 'Знакомься: Инь-Ян. Он сам исправляет раскладку на маке.',
    's3': 'Просто печатай. В чате — привет, как дела. В терминале — гит статус. Значок крутнулся — значит, исправил.',
    's4': 'В отличие от обычных свитчеров, Инь-Ян понимает контекст фразы, не ломает код и ссылки, '
          'не трогает правильные слова и учится отдельно в каждой программе.',
    's4b': 'Пунто — бесплатный. Карамба — четыреста девяносто девять рублей в год. '
           'Инь-Ян — бесплатно, и код открыт.',
    's5': 'Работает без интернета, весит сорок мегабайт, и твой текст никуда не уходит.',
    's6': 'Инь-Ян. Ссылка в профиле.',
}

here = os.path.dirname(os.path.abspath(__file__))
name = sys.argv[1] if len(sys.argv) > 1 else 'denis'
voice = PiperVoice.load(os.path.join(here, '.venv', 'voices', f'ru_RU-{name}-medium.onnx'))
cfg = SynthesisConfig(length_scale=0.88)  # чуть быстрее обычного — темп рилса

out = os.path.join(here, 'audio')
os.makedirs(out, exist_ok=True)
durations = {}
for key, text in LINES.items():
    path = os.path.join(out, f'{key}.wav')
    with wave.open(path, 'wb') as w:
        voice.synthesize_wav(text, w, syn_config=cfg)
    with wave.open(path) as w:
        durations[key] = round(w.getnframes() / w.getframerate(), 2)
json.dump(durations, open(os.path.join(here, 'voice.json'), 'w'), indent=1)
print(name, durations, 'итого', round(sum(durations.values()), 1), 'с')
