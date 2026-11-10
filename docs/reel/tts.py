# Озвучка рилса нейросетью Silero v4 (офлайн). Два варианта текста: classic и goth.
# Каждая реплика — отдельный wav в audio/<вариант>/; длительности — в voice-<вариант>.json,
# по ним reel.html растягивает сцены под голос.
# Запуск: .venv/bin/python tts.py classic [голос]   голоса: aidar baya kseniya xenia eugene
# «+» перед гласной — ударение (иначе «Инь-Ян» читается криво).
import json, os, re, subprocess, sys, urllib.request
import torch, soundfile as sf

LINES = {
    'classic': {
        's1': 'Опять напечатал абракадабру не на той раскладке?',
        's2': 'Знакомься: Инь, Я+н. Он сам исправляет раскладку на маке!',
        's3': 'Просто печатай. В чате — привет, как дела. В терминале — гит ст+атус. '
              'Значок крутнулся — значит, исправил.',
        's4': 'В отличие от обычных свитчеров, Инь, Я+н понимает контекст фразы, не ломает код и ссылки, '
              'не трогает правильные слова и учится отдельно в каждой программе.',
        's4b': 'У Пу+нто закрытый код, а по лицензии статистика уходит в Яндекс. '
               'Карамба — четыреста девяносто девять рублей в год. '
               'Инь, Я+н — бесплатно, код открыт, и всё без интернета!',
        's5': 'Работает без интернета, весит сорок мегабайт, и твой текст никуда не уходит.',
        's6': 'Инь, Я+н. Ссылка в профиле!',
    },
    # Готика: короткие фразы, паузы, низко и медленно (SSML).
    'goth': {
        's1': 'Ты снова печатаешь... <break time="300ms"/> не на той раскладке.',
        's2': 'Инь, Я+н. <break time="400ms"/> Он исправит всё. <break time="200ms"/> Сам.',
        's3': 'Просто печатай. <break time="300ms"/> Привет, как дела. <break time="500ms"/> Гит ст+атус. '
              '<break time="300ms"/> Знак обернулся — ошибки больше нет.',
        's4': 'Он не гадает по буквам. <break time="200ms"/> Он понимает смысл. <break time="200ms"/> '
              'Не трогает код. Не трогает правильное. <break time="200ms"/> И помнит каждую программу.',
        's4b': 'Пу+нто — закрытый код. <break time="200ms"/> Статистика — в Яндекс. <break time="300ms"/> '
               'Карамба — четыреста девяносто девять рублей в год. '
               '<break time="400ms"/> Инь, Я+н — бесплатно. <break time="200ms"/> Код открыт.',
        's5': 'Без интернета. <break time="200ms"/> Без следов. <break time="300ms"/> Твой текст остаётся с тобой.',
        's6': 'Инь, Я+н. <break time="300ms"/> Ссылка в профиле.',
    },
}
SPEAKER = {'classic': 'xenia', 'goth': 'aidar'}
PROSODY = {'classic': None, 'goth': ('slow', 'x-low')}
TEMPO = {'classic': 1.08, 'goth': 1.0}

# Образец своего голоса для ESpeech: файл и его ТОЧНЫЙ текст. Если файла нет — озвучивает Silero.
REF_AUDIO = 'voice-ref/ref.wav'
REF_TEXT = 'По восемь-одиннадцать секунд каждый образец. Или прикрепите в чат, пока вы записываете.'
# Готика из того же голоса: медленнее и на 3 полутона ниже
ESPEECH_SPEED = {'classic': 1.0, 'goth': 0.85}
PITCH = {'classic': 1.0, 'goth': 2 ** (-3 / 12)}
ESPEECH_TEMPO = {'classic': 1.2, 'goth': 1.0}

here = os.path.dirname(os.path.abspath(__file__))
variant = sys.argv[1] if len(sys.argv) > 1 else 'classic'
use_espeech = os.path.exists(os.path.join(here, REF_AUDIO))
out = os.path.join(here, 'audio', variant)
os.makedirs(out, exist_ok=True)


def ffmpeg_af(path, af):  # обработать файл фильтром ffmpeg на месте
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', path, '-af', af, path + '.tmp.wav'], check=True)
    os.replace(path + '.tmp.wav', path)


if use_espeech:
    from espeech import ESpeech
    engine, name = ESpeech(), 'ESpeech (твой голос)'
else:
    speaker = SPEAKER[variant]
    model_path = os.path.join(here, '.venv', 'v4_ru.pt')
    if not os.path.exists(model_path):
        urllib.request.urlretrieve('https://models.silero.ai/models/tts/ru/v4_ru.pt', model_path)
    model = torch.package.PackageImporter(model_path).load_pickle('tts_models', 'model')
    name = f'Silero {speaker}'

# tts.py goth s2 s4b — переозвучить только эти реплики, остальные длительности берём из прошлого раза
only = sys.argv[2:]
json_path = os.path.join(here, f'voice-{variant}.json')
durations = json.load(open(json_path)) if only and os.path.exists(json_path) else {}
for key, text in LINES[variant].items():
    if only and key not in only:
        continue
    path = os.path.join(out, f'{key}.wav')
    if use_espeech:
        # SSML ESpeech не понимает: паузы превращаем в многоточие
        plain = re.sub(r'\s*<break[^>]*/>\s*', '… ', text)
        wav, sr = engine.say(os.path.join(here, REF_AUDIO), REF_TEXT, plain, speed=ESPEECH_SPEED[variant])
        sf.write(path, wav, sr)
        if PITCH[variant] != 1:  # ниже тоном при той же длине
            p = PITCH[variant]
            ffmpeg_af(path, f'asetrate={sr}*{p:.4f},aresample={sr},atempo={1 / p:.4f}')
        if ESPEECH_TEMPO[variant] != 1:  # бодрее без изменения тона
            ffmpeg_af(path, f'atempo={ESPEECH_TEMPO[variant]}')
    else:
        p = PROSODY[variant]
        body = f'<prosody rate="{p[0]}" pitch="{p[1]}">{text}</prosody>' if p else text
        wav = model.apply_tts(ssml_text=f'<speak>{body}</speak>', speaker=speaker, sample_rate=48000,
                              put_accent=True, put_yo=True)
        sf.write(path, wav.numpy(), 48000)
        if TEMPO[variant] != 1:  # ускорение без изменения высоты голоса
            ffmpeg_af(path, f'atempo={TEMPO[variant]}')
    durations[key] = round(sf.info(path).duration, 2)
    print(key, durations[key], 'с', flush=True)
json.dump(durations, open(json_path, 'w'), indent=1)
print(variant, name, 'итого', round(sum(durations.values()), 1), 'с')
