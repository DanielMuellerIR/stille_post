#!/usr/bin/env python3
"""Begrenzter Dateivergleich. Keine Produktkonfiguration, kein Cloud-ASR."""
import argparse
import array
import hashlib
import json
import math
import random
import re
import shutil
import socket
import subprocess
import threading
import time
import urllib.request
import wave
from pathlib import Path

HERE = Path(__file__).resolve().parent


def run(args, **kwargs):
    return subprocess.run(args, check=True, timeout=kwargs.pop('timeout', 600), **kwargs)


def save(file, value):
    file.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def read_wav(file):
    with wave.open(str(file)) as w:
        assert (w.getnchannels(), w.getsampwidth(), w.getframerate()) == (1, 2, 16000)
        return array.array('h', w.readframes(w.getnframes()))


def write_wav(file, values):
    with wave.open(str(file), 'wb') as w:
        w.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
        w.writeframes(array.array('h', (max(-32768, min(32767, round(v))) for v in values)).tobytes())


def digest(file):
    checksum=hashlib.sha256()
    with file.open('rb') as stream:
        for block in iter(lambda:stream.read(4*1024*1024),b''):
            checksum.update(block)
    return checksum.hexdigest()


def verify_inputs(work):
    for case in json.loads((work/'manifest.json').read_text()):
        assert digest(work/'audio'/case['wav'])==case['sha256'], case['id']
        joined=array.array('h')
        for segment in case['segments']:
            joined.extend(read_wav(work/'audio'/segment))
        assert joined==read_wav(work/'audio'/case['wav']), case['id']
    for model in json.loads((HERE/'models.json').read_text()).values():
        for spec in model['files']:
            assert digest(work/'models'/spec['name'])==spec['sha256'], spec['name']


def synthesize(work):
    corpus = json.loads((HERE / 'corpus.json').read_text())
    audio = work / 'audio'
    audio.mkdir(exist_ok=True)
    manifest = []
    rng = random.Random(corpus['seed'])
    for case in corpus['cases']:
        kind = case['kind']
        samples = []
        if case['text']:
            for i, part in enumerate(case.get('parts') or [case['text']]):
                aiff, wav = audio / 'part.aiff', audio / 'part.wav'
                run(['say', '-v', case['voice'], '-r', str(corpus['rate']), '-o', str(aiff), part])
                run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', str(aiff), str(wav)])
                if i:
                    samples.extend([0] * round(corpus['pauseSec'] * 16000))
                samples.extend(read_wav(wav))
            rms = math.sqrt(sum(x*x for x in samples) / len(samples))
            gain = 32768 * 10**(corpus['normalRmsDb']/20) / rms
            samples = [x * gain for x in samples]
        else:
            samples = [0] * (5 * 16000)
        # Die Maske entsteht aus sauberer Sprache vor Absenkung/Rauschen.
        activity = []
        for offset in range(0, len(samples), 480):
            frame = samples[offset:offset+480]
            rms = math.sqrt(sum(x*x for x in frame) / len(frame))
            if case['text'] and rms > 32768 * 10**(-45/20):
                activity.append([offset + 8000, min(offset+480, len(samples)) + 8000])
        if kind == 'quiet':
            gain = 10**((corpus['quietRmsDb']-corpus['normalRmsDb'])/20)
            samples = [x*gain for x in samples]
        if kind in ('noise', 'noise-speech'):
            sigma = 32768 * 10**(corpus['noiseRmsDb']/20)
            samples = [x + rng.gauss(0, sigma) for x in samples]
        if kind == 'clicks':
            for offset in (8000, 24000, 48000):
                for i in range(320):
                    samples[offset+i] = 20000 * math.exp(-i/40) * (1 if i%2 else -1)
        samples = [0]*8000 + samples + [0]*8000
        dest = audio / (case['id']+'.wav')
        write_wav(dest, samples)
        segments = []
        for index, offset in enumerate(range(0, len(samples), 240000)):
            name = case['id'] + f'-{index:03d}.wav'
            write_wav(audio / name, samples[offset:offset+240000])
            segments.append(name)
        manifest.append(dict(case, wav=dest.name, segments=segments, activity=activity,
                             samples=len(samples), sha256=hashlib.sha256(dest.read_bytes()).hexdigest()))
    for name in ('part.aiff', 'part.wav'):
        (audio / name).unlink(missing_ok=True)
    save(work/'manifest.json', manifest)


def download(work, engine):
    pins = json.loads((HERE/'models.json').read_text())[engine]
    dest = work/'models'
    for spec in pins['files']:
        target = dest/spec['name']
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists() or hashlib.sha256(target.read_bytes()).hexdigest() != spec['sha256']:
            url = f"https://huggingface.co/{pins['repo']}/resolve/{pins['revision']}/{spec['name']}"
            temp = target.with_suffix(target.suffix+'.part')
            with urllib.request.urlopen(url, timeout=120) as response, temp.open('wb') as out:
                shutil.copyfileobj(response, out)
            assert temp.stat().st_size == spec['bytes'], spec['name']
            assert hashlib.sha256(temp.read_bytes()).hexdigest() == spec['sha256'], spec['name']
            temp.replace(target)
    print(engine, 'verified bytes', sum(x['bytes'] for x in pins['files']))


def build(work):
    # Kopie des tatsächlichen Produktkerns; keine zweite VAD-Implementierung.
    core = work/'Core'
    if core.exists():
        record = work/'core-hashes.json'
        current = {str(p.relative_to(core)): hashlib.sha256(p.read_bytes()).hexdigest()
                   for p in core.rglob('*') if p.is_file()}
        if not record.exists() or current != json.loads(record.read_text()):
            raise RuntimeError('Core contains unowned or changed files; use a new work directory')
        source = HERE.parents[2]/'Sources/StillePostCore'
        expected = {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in source.rglob('*') if p.is_file()}
        if current != expected:
            raise RuntimeError('Product core changed; use a new work directory')
    else:
        if any((work/name).exists() for name in ('Package.swift','Benchmark','Package.resolved')):
            raise RuntimeError('Unowned package files exist; use a new work directory')
        shutil.copytree(HERE.parents[2]/'Sources/StillePostCore', core)
    shutil.copyfile(HERE/'Package.swift', work/'Package.swift')
    shutil.copytree(HERE/'Benchmark', work/'Benchmark', dirs_exist_ok=True)
    save(work/'core-hashes.json', {str(p.relative_to(core)): hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in core.rglob('*') if p.is_file()})
    with (work/'build.log').open('w') as log:
        run(['swift', 'build', '--package-path', str(work), '--scratch-path', str(work/'build'), '-c', 'release'],
            stdout=log, stderr=subprocess.STDOUT, timeout=1200)


def infer(port, file, language):
    boundary = 'ASRVADComparisonBoundary'
    payload = bytearray()
    for name, value in [('response_format','json'), ('language',language), ('temperature','0')]:
        payload.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    payload.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="input.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode())
    payload.extend(file.read_bytes())
    payload.extend(f'\r\n--{boundary}--\r\n'.encode())
    request = urllib.request.Request(f'http://127.0.0.1:{port}/inference', data=bytes(payload),
                                     headers={'Content-Type':f'multipart/form-data; boundary={boundary}'})
    with urllib.request.urlopen(request, timeout=180) as response:
        return json.load(response)['text'].strip()


def whisper(work, model, binary, cold_only=False):
    manifest = json.loads((work/'manifest.json').read_text())
    output = []
    port = 18171
    with socket.socket() as probe:
        probe.bind(('127.0.0.1',port))
    for cold in range(3):
        started = time.monotonic()
        with (work/f'whisper-{cold}.log').open('w') as log:
            process = subprocess.Popen([str(binary), '-m', str(model), '--host', '127.0.0.1',
                                        '--port', str(port), '-t', '4'], stdout=log, stderr=subprocess.STDOUT)
            peak = 0
            monitor_stop = threading.Event()
            def memory():
                nonlocal peak
                value = subprocess.run(['ps','-o','rss=','-p',str(process.pid)], capture_output=True, text=True)
                if value.stdout.strip():
                    peak = max(peak, int(value.stdout.strip()) * 1024)
            def monitor():
                while not monitor_stop.wait(.1):
                    memory()
            monitor_thread = threading.Thread(target=monitor)
            monitor_thread.start()
            def transcribe(case):
                begin = time.monotonic()
                texts = []
                for name in case['segments']:
                    memory()
                    texts.append(infer(port, work/'audio'/name, case['language']))
                memory()
                return dict(id=case['id'], seconds=time.monotonic()-begin, text=' '.join(texts),
                            segmentTexts=texts, rssObservedBytes=peak)
            try:
                deadline = time.monotonic()+90
                while True:
                    if process.poll() is not None:
                        raise RuntimeError('Whisper exited before readiness')
                    try:
                        with urllib.request.urlopen(f'http://127.0.0.1:{port}/health', timeout=1) as r:
                            if r.status == 200:
                                break
                    except OSError:
                        pass
                    if time.monotonic() >= deadline:
                        raise TimeoutError('Whisper startup')
                    time.sleep(.1)
                loaded = time.monotonic()-started
                row = transcribe(manifest[0])
                output.append(dict(row, phase='process-cold', repeat=cold, initSeconds=loaded,
                                   totalSeconds=time.monotonic()-started))
                if cold == 2 and not cold_only:
                    transcribe(manifest[0])
                    for repeat in range(3):
                        for case in manifest:
                            output.append(dict(transcribe(case), phase='warm', repeat=repeat))
                    # Dieselbe ASR-Instanz prüft echte VAD-Ausgaben beider Detektoren.
                    for engine in ('rms','silero'):
                        data = json.loads((work/f'{engine}.json').read_text())
                        for row in data['rows']:
                            if row['repeat'] == 0 and row['id'].endswith(('quiet','noise-speech','pauses')):
                                case = next(x for x in manifest if x['id']==row['id'])
                                texts = [infer(port, work/'vad-audio'/n, case['language']) for n in row['files']]
                                output.append(dict(id=row['id'],phase='vad-'+engine,repeat=0,
                                                   text=' '.join(texts), segmentTexts=texts))
            finally:
                monitor_stop.set()
                monitor_thread.join(timeout=5)
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait(timeout=5)
        save(work/('whisper-cold-only.json' if cold_only else 'whisper.json'),output)


def cold_probes(work, model, binary):
    # Beide Wege: Elternprozess-Start bis vollständig vorliegendes Ergebnis.
    # Vorhandene Modell-/OS-Caches bleiben bewusst erhalten.
    executable=work/'build/release/CompareAudio'
    isolated=['/usr/bin/sandbox-exec','-p','(version 1) (allow default) (deny network*)']
    measurements=[]
    with (work/'cold-probes.log').open('w') as log:
        for engine in ('rms','silero','parakeet'):
            for repeat in range(3):
                before=set(work.glob(engine+'-cold-*.json'))
                started=time.monotonic()
                process=subprocess.Popen(isolated+[str(executable),engine,str(work),'cold'],
                                         stdout=log,stderr=subprocess.STDOUT)
                try:
                    while not (set(work.glob(engine+'-cold-*.json'))-before):
                        if process.poll() is not None:
                            if set(work.glob(engine+'-cold-*.json'))-before:
                                break
                            raise RuntimeError('Cold probe exited before result')
                        if time.monotonic()-started>90:
                            raise TimeoutError('Cold probe result')
                        time.sleep(.005)
                    measurements.append(dict(engine=engine,repeat=repeat,seconds=time.monotonic()-started))
                    process.wait(timeout=15)
                    assert process.returncode==0
                finally:
                    if process.poll() is None:
                        process.kill();process.wait(timeout=5)
    save(work/'cold-launch.json',measurements)
    whisper(work,model,binary,cold_only=True)


def measure(work, model, binary):
    if any((work/(engine+'.json')).exists() for engine in ('rms','silero','parakeet','whisper')):
        raise RuntimeError('Measurement results already exist; use a new work directory')
    verify_inputs(work)
    executable=work/'build/release/CompareAudio'
    isolated=['/usr/bin/sandbox-exec','-p','(version 1) (allow default) (deny network*)']
    with (work/'measurement.log').open('w') as log:
        run(isolated+[str(executable),'gate',str(work)],stdout=log,stderr=subprocess.STDOUT)
        for engine in ('rms','silero','parakeet'):
            for _ in range(3):
                run(isolated+[str(executable),engine,str(work),'cold'],stdout=log,stderr=subprocess.STDOUT)
            run(isolated+[str(executable),engine,str(work)],stdout=log,stderr=subprocess.STDOUT)
    whisper(work,model,binary)
    summarize(work)


def tokens(text):
    return re.findall(r'[^\W_]+', text.casefold(), re.UNICODE)


def distance(a, b):
    row = list(range(len(b)+1))
    for i, left in enumerate(a, 1):
        new = [i]
        for j, right in enumerate(b, 1):
            new.append(min(new[-1]+1, row[j]+1, row[j-1]+(left != right)))
        row = new
    return row[-1]


def summarize(work):
    manifest = {x['id']:x for x in json.loads((work/'manifest.json').read_text())}
    result = {}
    for engine in ('whisper','parakeet'):
        data = json.loads((work/f'{engine}.json').read_text())
        rows = data if isinstance(data,list) else data['rows']
        scored = []
        for row in rows:
            ref = tokens(manifest[row['id']]['reference'])
            hyp = tokens(row['text'])
            scored.append(dict(row, referenceWords=len(ref), wordEdits=distance(ref,hyp),
                               characterEdits=distance(' '.join(ref),' '.join(hyp)),
                               referenceCharacters=len(' '.join(ref))))
        save(work/f'{engine}-scored.json',scored)
        result[engine] = scored
    for engine in ('rms','silero'):
        data = json.loads((work/f'{engine}.json').read_text())
        for row in data['rows']:
            case=manifest[row['id']]
            spans=row['ranges']
            total=sum(b-a for a,b in case['activity'])
            kept=0
            for a,b in case['activity']:
                intervals=sorted((max(a,x),min(b,y)) for x,y in spans if min(b,y)>max(a,x))
                end=a
                for x,y in intervals:
                    kept += max(0,y-max(x,end));end=max(end,y)
            row['activitySamples']=total
            row['retainedActivitySamples']=kept
            row['activityRetention']=kept/total if total else None
        save(work/f'{engine}-scored.json',data)
    print('Scored raw results saved; meaning still requires explicit review.')


if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('action',choices=['corpus','download-silero','download-parakeet','build','measure','cold','whisper','score'])
    parser.add_argument('--work',type=Path,required=True)
    parser.add_argument('--whisper-model',type=Path)
    parser.add_argument('--whisper-binary',type=Path,default=Path('/opt/homebrew/bin/whisper-server'))
    args=parser.parse_args()
    args.work.mkdir(parents=True,exist_ok=True)
    if args.action=='corpus': synthesize(args.work)
    elif args.action.startswith('download-'): download(args.work,args.action.split('-')[1])
    elif args.action=='build': build(args.work)
    elif args.action in ('measure','cold','whisper'):
        if not args.whisper_model: parser.error('--whisper-model is required')
        {'measure':measure,'cold':cold_probes,'whisper':whisper}[args.action](args.work,args.whisper_model,args.whisper_binary)
    elif args.action=='score': summarize(args.work)
