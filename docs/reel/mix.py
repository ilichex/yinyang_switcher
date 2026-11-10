# Звук рилса: синтезирует бит и эффекты по timeline.json, кладёт голос из audio/*.wav,
# приглушает музыку под голосом (ducking). Своя музыка — никаких проблем с правами.
# Выход: mix.wav (всё) и voice_sfx.wav (без музыки — чтобы подложить трек в Instagram).
import json, os, wave
import numpy as np

SR = 48000
here = os.path.dirname(os.path.abspath(__file__))
tl = json.load(open(os.path.join(here, 'timeline.json')))
N = int((tl['duration'] + 0.3) * SR)
rng = np.random.default_rng(7)

def env(n, decay):  # экспоненциальный спад
    return np.exp(-np.arange(n) / (decay * SR))

def add(buf, t, sig, gain=1.0):
    i = int(t * SR)
    if i >= len(buf): return
    sig = sig[: len(buf) - i]
    buf[i:i + len(sig)] += sig * gain

def smooth(x, k):  # грубый ФНЧ скользящим средним
    return np.convolve(x, np.ones(k) / k, mode='same')

def tone(freq, dur, wave_='sine'):
    t = np.arange(int(dur * SR)) / SR
    ph = 2 * np.pi * np.cumsum(np.broadcast_to(freq, t.shape)) / SR
    if wave_ == 'saw':
        return sum(np.sin(k * ph) / k for k in range(1, 7)) * 0.6
    return np.sin(ph)

midi = lambda m: 440 * 2 ** ((m - 69) / 12)

# --- музыка ---
music = np.zeros(N)
BPM = 120; beat = 60 / BPM
drop = next(e['t'] for e in tl['events'] if e['type'] == 'boom')  # бит стартует, когда значок «приземлился»
CHORDS = [  # бас, аккорд: Am – F – C – G
    (33, [57, 60, 64]), (29, [53, 57, 60]), (36, [55, 60, 64]), (31, [55, 59, 62])]
bar = 4 * beat
nbars = int(tl['duration'] / bar) + 1
for b in range(nbars):
    root, chord = CHORDS[b % 4]
    t0 = b * bar
    # подложка-пэд: всегда, тихо
    for m in chord:
        p = tone(midi(m) * 1.003, bar) + tone(midi(m) * 0.997, bar)
        a = np.minimum(1, np.arange(len(p)) / (0.3 * SR)) * np.minimum(1, (len(p) - np.arange(len(p))) / (0.3 * SR))
        add(music, t0, p * a, 0.025)
    for s in range(16):  # шестнадцатые
        t = t0 + s * beat / 4
        live = t >= drop - 0.01
        if s % 4 == 0 and live:  # бочка
            n = int(0.35 * SR)
            f = 45 + 110 * env(n, 0.03)
            add(music, t, tone(f, 0.35) * env(n, 0.12), 0.9)
        if s % 8 == 4 and live:  # хлопок на 2 и 4
            n = int(0.15 * SR)
            add(music, t, np.diff(rng.standard_normal(n + 1)) * env(n, 0.04), 0.12)
        if s % 2 == 0:  # хэт на восьмых (до дропа — тише)
            n = int(0.05 * SR)
            add(music, t, np.diff(rng.standard_normal(n + 1)) * env(n, 0.012), 0.05 if live else 0.025)
        if s % 2 == 1 and live:  # бас «качается» под бочку
            n = int(beat / 2 * SR)
            add(music, t - beat / 4, tone(midi(root + 12), beat / 2, 'saw') * env(n, 0.09), 0.16)
        if live:  # арпеджио
            m = chord[s % 3] + 12 * (1 + (s // 3) % 2)
            n = int(0.18 * SR)
            add(music, t, (tone(midi(m), 0.18) + 0.3 * tone(midi(m) * 2, 0.18)) * env(n, 0.05), 0.045)

# --- эффекты ---
sfx = np.zeros(N)
def noise(dur): return rng.standard_normal(int(dur * SR))
for e in tl['events']:
    t, ty = e['t'], e['type']
    if ty == 'key':
        n = int(0.012 * SR)
        add(sfx, t, np.diff(rng.standard_normal(n + 1)) * env(n, 0.003) + tone(2400, 0.012) * env(n, 0.002) * 0.3, 0.22)
    elif ty == 'error':
        for k, f in enumerate([330, 220]):
            n = int(0.14 * SR)
            add(sfx, t + k * 0.15, np.sign(tone(f, 0.14)) * env(n, 0.08), 0.08)
    elif ty in ('whoosh', 'spin'):
        d = 0.45 if ty == 'whoosh' else 0.3
        n = int(d * SR)
        x = smooth(noise(d), 12) * np.sin(np.pi * np.arange(n) / n) ** 2
        add(sfx, t - d / 2, x, 0.5 if ty == 'whoosh' else 0.25)
    elif ty == 'riser':
        d = drop - t
        n = int(d * SR)
        ramp = (np.arange(n) / n) ** 2
        add(sfx, t, (tone(200 + 900 * ramp, d) * 0.3 + smooth(noise(d), 4)) * ramp, 0.18)
    elif ty == 'boom':
        n = int(1.0 * SR)
        add(sfx, t, tone(30 + 50 * env(n, 0.05), 1.0) * env(n, 0.35) + smooth(noise(1.0), 3) * env(n, 0.15) * 0.3, 0.6)
    elif ty == 'ding':
        n = int(0.6 * SR)
        add(sfx, t, (tone(1318.5, 0.6) + 0.6 * tone(1975.5, 0.6)) * env(n, 0.18), 0.12)
    elif ty == 'pop':
        n = int(0.07 * SR)
        f0 = 500 * 2 ** (e.get('i', 0) / 6)
        add(sfx, t, tone(f0 + f0 * 0.8 * (np.arange(n) / n), 0.07) * env(n, 0.02), 0.25)

# --- голос ---
voice = np.zeros(N)
for e in tl['events']:
    if e['type'] != 'voice': continue
    with wave.open(os.path.join(here, 'audio', f"{e['id']}.wav")) as w:
        sr = w.getframerate()
        x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16) / 32768
    x = np.interp(np.arange(int(len(x) * SR / sr)) * sr / SR, np.arange(len(x)), x)  # пересэмплинг в 48 кГц
    add(voice, e['t'], x / (np.abs(x).max() + 1e-9), 0.9)

# ducking: где звучит голос, музыка тише
active = smooth((np.abs(voice) > 0.02).astype(float), int(0.25 * SR)) > 0.05
duck = smooth(np.where(active, 0.35, 1.0), int(0.15 * SR))
fade = np.minimum(1, (N - np.arange(N)) / (0.8 * SR))  # затухание в конце

def master(x):
    x = np.tanh(x * 1.2) / np.tanh(1.2)
    return x / (np.abs(x).max() + 1e-9) * 0.89  # около −1 дБ

def save(name, x):
    with wave.open(os.path.join(here, name), 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes((x * 32767).astype(np.int16).tobytes())

save('mix.wav', master((music * duck * 0.55 + sfx * 0.7 + voice) * fade))
save('voice_sfx.wav', master((sfx * 0.7 + voice) * fade))
print('звук готов:', round(N / SR, 1), 'с')
