# Обёртка над ESpeech-TTS-1 RL-V2 (F5-TTS, дообучена на русском, Apache 2.0).
# Клонирует голос по образцу: нужен короткий wav/m4a (до ~12 с) и ТОЧНЫЙ текст этого образца.
# Ударения ставит RUAccent; свои можно указать «+» перед гласной.
import re, time
import numpy as np
from huggingface_hub import hf_hub_download
from ruaccent import RUAccent
from f5_tts.infer.utils_infer import infer_process, load_model, load_vocoder, preprocess_ref_audio_text
from f5_tts.model import DiT

REPO = 'ESpeech/ESpeech-TTS-1_RL-V2'
CFG = dict(dim=1024, depth=22, heads=16, ff_mult=2, text_dim=512, conv_layers=4)


class ESpeech:
    def __init__(self):
        t = time.time()
        ckpt = hf_hub_download(REPO, 'espeech_tts_rlv2.pt')
        vocab = hf_hub_download(REPO, 'vocab.txt')
        self.model = load_model(DiT, CFG, ckpt, vocab_file=vocab)
        self.vocoder = load_vocoder()
        self.acc = RUAccent()
        self.acc.load(omograph_model_size='turbo3.1', use_dictionary=True, tiny_mode=False)
        print(f'ESpeech загружен за {time.time() - t:.0f} с')

    def accent(self, text):
        # автоударения на всю фразу, а слова с ручным «+» (Я+н, Пу+нто) возвращаем как задано
        manual = {w.replace('+', ''): w for w in re.findall(r'\w*\+\w+', text)}
        text = text.replace('+', '')
        try:
            out = self.acc.process_all(text)
        except Exception:  # модель омографов RUAccent иногда падает на длинной фразе — режем по запятым
            parts = re.split(r'(?<=[,.!?…])\s+', text)
            out = ' '.join(self._safe(p) for p in parts)
        for plain, mine in manual.items():
            # слово в выводе может уже содержать «+» в другом месте — сравниваем без них
            out = re.sub(r'(?<![\w+])' + r'\+?'.join(map(re.escape, plain)) + r'\+?(?![\w+])', mine, out)
        return out

    def _safe(self, part):
        try:
            return self.acc.process_all(part)
        except Exception:
            return part  # без ударений лучше, чем падение

    def say(self, ref_audio, ref_text, text, speed=1.0, nfe=32, seed=42):
        import torch
        torch.manual_seed(seed)
        ref, ref_txt = preprocess_ref_audio_text(ref_audio, self.accent(ref_text))
        wav, sr, _ = infer_process(ref, ref_txt, self.accent(text), self.model, self.vocoder,
                                   cross_fade_duration=0.15, nfe_step=nfe, speed=speed)
        return np.asarray(wav, dtype=np.float32), sr


if __name__ == '__main__':  # проверка скорости и памяти на временном образце
    import resource, sys, soundfile as sf
    e = ESpeech()
    t = time.time()
    wav, sr = e.say(sys.argv[1], sys.argv[2], sys.argv[3])
    sf.write(sys.argv[4], wav, sr)
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 2**30
    print(f'синтез {len(wav) / sr:.1f} с аудио за {time.time() - t:.0f} с, пик памяти {peak:.1f} ГБ')
