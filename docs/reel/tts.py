# Озвучка рилса твоим голосом (офлайн). Движки: Qwen3-TTS (основной), ESpeech, Silero (запасной).
# Каждая реплика — отдельный wav в audio/<вариант>/; длительности — в voice-<вариант>.json,
# по ним reel.html растягивает сцены под голос.
# Запуск: .venv-qwen/bin/python tts.py classic [s2 s4 ...]   ESpeech/Silero: ENGINE=espeech .venv/bin/python tts.py
# «+» перед гласной — ударение для ESpeech/Silero; для Qwen снимается.
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

# Qwen3-TTS — победитель сравнения на слух (ab.py). Живёт в своём venv: .venv-qwen
QWEN_MODEL = 'Qwen/Qwen3-TTS-12Hz-1.7B-Base'
QWEN_REF = 'voice-ref/ref-clean.wav'  # образец после шумоподавления — звучал лучше всего
MAX_PAUSE = 0.18  # паузы внутри реплики длиннее этого укорачиваем
# Ускорение без «металла»: Rubber Band R3 (brew install rubberband), не ffmpeg atempo
# зерно генерации по репликам: подобрано, где с умолчанием (7) модель срывалась
SEEDS = {"classic": {"s6": 11}}
QWEN_TEMPO = 1.25  # выбран на слух (×1,15 и ×1,25 сравнивались)

here = os.path.dirname(os.path.abspath(__file__))
variant = sys.argv[1] if len(sys.argv) > 1 else 'classic'
# движок: ENGINE=qwen|espeech|silero; по умолчанию Qwen3, если есть образец голоса
ENGINE = os.environ.get('ENGINE') or ('qwen' if os.path.exists(os.path.join(here, QWEN_REF)) else
                                      'espeech' if os.path.exists(os.path.join(here, REF_AUDIO)) else 'silero')
use_espeech = ENGINE == 'espeech'
out = os.path.join(here, 'audio', variant)
os.makedirs(out, exist_ok=True)


def shorten_pauses(wav, sr, max_pause=MAX_PAUSE, top_db=38):
    """Склеивает речь, оставляя между кусками не больше max_pause тишины."""
    import numpy as np, librosa
    parts = librosa.effects.split(wav, top_db=top_db, frame_length=1024, hop_length=256)
    if len(parts) == 0:
        return wav
    keep, gap = [], int(max_pause * sr)
    for i, (a, b) in enumerate(parts):
        if i:
            prev_end = parts[i - 1][1]
            keep.append(wav[prev_end: prev_end + min(a - prev_end, gap)])
        keep.append(wav[a:b])
    pad = int(0.05 * sr)  # чуть воздуха по краям
    return np.concatenate([np.zeros(pad, wav.dtype)] + keep + [np.zeros(pad, wav.dtype)])


def qwen_text(text):
    """Для Qwen: без SSML и «+», «Инь-Ян» через дефис (запятая давала лишнюю паузу)."""
    t = re.sub(r'\s*<break[^>]*/>\s*', ', ', text).replace('+', '')
    return re.sub(r'Инь,?\s*Ян', 'Инь-Ян', t)


def ffmpeg_af(path, af):  # обработать файл фильтром ffmpeg на месте
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', path, '-af', af, path + '.tmp.wav'], check=True)
    os.replace(path + '.tmp.wav', path)


if ENGINE == 'qwen':
    import numpy as np, librosa
    from qwen_tts import Qwen3TTSModel
    dev = 'mps' if torch.backends.mps.is_available() else 'cpu'
    qwen = Qwen3TTSModel.from_pretrained(QWEN_MODEL, device_map=dev, dtype=torch.float16, attn_implementation='sdpa')
    name = 'Qwen3-TTS (твой голос)'
elif use_espeech:
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
    raw = os.path.join(out, 'raw', f'{key}.wav')  # неускоренный голос: менять темп без переозвучки
    if ENGINE == 'qwen' and os.environ.get('TEMPO_ONLY') and os.path.exists(raw):
        subprocess.run(['rubberband', '-3', '-q', '-T', str(QWEN_TEMPO), raw, path], check=True)
    elif ENGINE == 'qwen':
        # длинную реплику — по предложениям: на длинном тексте модель иногда «галлюцинирует»
        chunks = [c for c in re.split(r'(?<=[.!?])\s+', qwen_text(text)) if c.strip()]
        pieces = []
        for c in chunks:
            torch.manual_seed(int(os.environ.get("SEED") or SEEDS.get(variant, {}).get(key, 7)))  # одинаковый результат; SEED=… если реплика сорвалась
            wavs, sr = qwen.generate_voice_clone(text=c, language='Russian',
                                                 ref_audio=os.path.join(here, QWEN_REF), ref_text=REF_TEXT)
            pieces += [np.asarray(wavs[0], dtype=np.float32), np.zeros(int(0.2 * sr), np.float32)]
        wav = shorten_pauses(np.concatenate(pieces), sr)
        wav = librosa.resample(wav, orig_sr=sr, target_sr=48000, res_type='soxr_vhq')
        os.makedirs(os.path.dirname(raw), exist_ok=True)
        sf.write(raw, wav, 48000)
        subprocess.run(['rubberband', '-3', '-q', '-T', str(QWEN_TEMPO), raw, path], check=True)
    elif use_espeech:
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
