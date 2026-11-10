# A/B-сравнение озвучки на одной фразе. Каждый вариант — отдельный процесс (память 8 ГБ).
# Запуск: .venv/bin/python ab.py old|espeech|qwen|qwen06
import os, subprocess, sys, time
import numpy as np, soundfile as sf, librosa

here = os.path.dirname(os.path.abspath(__file__))
TEXT = 'Знакомься: Инь, Ян. Работает без интернета, весит сорок мегабайт, и твой текст никуда не уходит.'
REF_TEXT = 'По восемь-одиннадцать секунд каждый образец. Или прикрепите в чат, пока вы записываете.'
out_dir = os.path.join(here, 'ab'); os.makedirs(out_dir, exist_ok=True)
mode = sys.argv[1]
t = time.time()

if mode in ('old', 'espeech'):
    from espeech import ESpeech
    e = ESpeech()
    t = time.time()
    if mode == 'old':  # как было: сырой образец, 32 шага, atempo 1.2, линейный пересэмплинг
        wav, sr = e.say(os.path.join(here, 'voice-ref/ref.wav'), REF_TEXT, TEXT.replace('Инь, Ян', 'Инь, Я+н'))
        sf.write('/tmp/_ab.wav', wav, sr)
        subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', '/tmp/_ab.wav', '-af', 'atempo=1.2', '/tmp/_ab2.wav'], check=True)
        wav, sr = sf.read('/tmp/_ab2.wav', dtype='float32')
        wav = np.interp(np.arange(int(len(wav) * 48000 / sr)) * sr / 48000, np.arange(len(wav)), wav)
    else:  # очищенный образец, 64 шага, ускорение самой моделью, soxr
        wav, sr = e.say(os.path.join(here, 'voice-ref/ref-clean.wav'), REF_TEXT,
                        TEXT.replace('Инь, Ян', 'Инь, Я+н'), speed=1.15, nfe=64)
        wav = librosa.resample(wav, orig_sr=sr, target_sr=48000, res_type='soxr_vhq')
else:
    import torch
    from qwen_tts import Qwen3TTSModel
    name = 'Qwen/Qwen3-TTS-12Hz-1.7B-Base' if mode in ('qwen', 'qwenraw') else 'Qwen/Qwen3-TTS-12Hz-0.6B-Base'
    dev = 'mps' if torch.backends.mps.is_available() else 'cpu'
    m = Qwen3TTSModel.from_pretrained(name, device_map=dev, dtype=torch.float16, attn_implementation='sdpa')
    t = time.time()
    wavs, sr = m.generate_voice_clone(text=TEXT, language='Russian',
                                      ref_audio=os.path.join(here, 'voice-ref/ref.wav' if mode == 'qwenraw' else 'voice-ref/ref-clean.wav'), ref_text=REF_TEXT)
    wav = librosa.resample(np.asarray(wavs[0], dtype=np.float32), orig_sr=sr, target_sr=48000, res_type='soxr_vhq')

wav = wav / (np.abs(wav).max() + 1e-9) * 0.9
sf.write(os.path.join(out_dir, f'{mode}.wav'), wav, 48000)
import resource
print(f'{mode}: {len(wav) / 48000:.1f} с аудио за {time.time() - t:.0f} с, '
      f'пик памяти {resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 2**30:.1f} ГБ')
