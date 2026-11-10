# Озвучка рилса нейросетью Silero v4 (офлайн). Два варианта текста: classic и goth.
# Каждая реплика — отдельный wav в audio/<вариант>/; длительности — в voice-<вариант>.json,
# по ним reel.html растягивает сцены под голос.
# Запуск: .venv/bin/python tts.py classic [голос]   голоса: aidar baya kseniya xenia eugene
# «+» перед гласной — ударение (иначе «Инь-Ян» читается криво).
import json, os, subprocess, sys, urllib.request
import torch, soundfile as sf

LINES = {
    'classic': {
        's1': 'Опять напечатал абракадабру не на той раскладке?',
        's2': 'Знакомься: Инь Я+н. Он сам исправляет раскладку на маке!',
        's3': 'Просто печатай. В чате — привет, как дела. В терминале — гит ст+атус. '
              'Значок крутнулся — значит, исправил.',
        's4': 'В отличие от обычных свитчеров, Инь Я+н понимает контекст фразы, не ломает код и ссылки, '
              'не трогает правильные слова и учится отдельно в каждой программе.',
        's4b': 'Пунто — бесплатный. Карамба — четыреста девяносто девять рублей в год. '
               'Инь Я+н — бесплатно, и код открыт!',
        's5': 'Работает без интернета, весит сорок мегабайт, и твой текст никуда не уходит.',
        's6': 'Инь Я+н. Ссылка в профиле!',
    },
    # Готика: короткие фразы, паузы, низко и медленно (SSML).
    'goth': {
        's1': 'Ты снова печатаешь... <break time="300ms"/> не на той раскладке.',
        's2': 'Инь Я+н. <break time="400ms"/> Он исправит всё. <break time="200ms"/> Сам.',
        's3': 'Просто печатай. <break time="300ms"/> Привет, как дела. <break time="500ms"/> Гит ст+атус. '
              '<break time="300ms"/> Знак обернулся — ошибки больше нет.',
        's4': 'Он не гадает по буквам. <break time="200ms"/> Он понимает смысл. <break time="200ms"/> '
              'Не трогает код. Не трогает правильное. <break time="200ms"/> И помнит каждую программу.',
        's4b': 'Пунто. <break time="200ms"/> Карамба — четыреста девяносто девять рублей в год. '
               '<break time="400ms"/> Инь Я+н — бесплатно. <break time="200ms"/> Код открыт.',
        's5': 'Без интернета. <break time="200ms"/> Без следов. <break time="300ms"/> Твой текст остаётся с тобой.',
        's6': 'Инь Я+н. <break time="300ms"/> Ссылка в профиле.',
    },
}
SPEAKER = {'classic': 'xenia', 'goth': 'aidar'}
PROSODY = {'classic': None, 'goth': ('slow', 'x-low')}
TEMPO = {'classic': 1.08, 'goth': 1.0}

here = os.path.dirname(os.path.abspath(__file__))
variant = sys.argv[1] if len(sys.argv) > 1 else 'classic'
speaker = sys.argv[2] if len(sys.argv) > 2 else SPEAKER[variant]
model_path = os.path.join(here, '.venv', 'v4_ru.pt')
if not os.path.exists(model_path):
    urllib.request.urlretrieve('https://models.silero.ai/models/tts/ru/v4_ru.pt', model_path)
model = torch.package.PackageImporter(model_path).load_pickle('tts_models', 'model')

out = os.path.join(here, 'audio', variant)
os.makedirs(out, exist_ok=True)
durations = {}
for key, text in LINES[variant].items():
    p = PROSODY[variant]
    body = f'<prosody rate="{p[0]}" pitch="{p[1]}">{text}</prosody>' if p else text
    wav = model.apply_tts(ssml_text=f'<speak>{body}</speak>', speaker=speaker, sample_rate=48000,
                          put_accent=True, put_yo=True)
    path = os.path.join(out, f'{key}.wav')
    sf.write(path, wav.numpy(), 48000)
    if TEMPO[variant] != 1:  # ускорение без изменения высоты голоса
        subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', path, '-af', f'atempo={TEMPO[variant]}',
                        path + '.tmp.wav'], check=True)
        os.replace(path + '.tmp.wav', path)
    durations[key] = round(sf.info(path).duration, 2)
json.dump(durations, open(os.path.join(here, f'voice-{variant}.json'), 'w'), indent=1)
print(variant, speaker, durations, 'итого', round(sum(durations.values()), 1), 'с')
