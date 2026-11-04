#!/usr/bin/env python3
"""Startprüfung mit genau einem lokalen Rückfall auf das geprüfte Vorgängerpaket."""
import os,pathlib,subprocess,sys,tempfile,time

def main():
    bundle=pathlib.Path(__file__).resolve().parent
    # Diagnose- und Steueraufrufe sollen nicht auf eine GUI-Startbestätigung warten.
    if any(x in sys.argv for x in ['--toggle','--audio-devices','--smoke-test','--cli']):
        return subprocess.call([str(bundle/'AppRun'),*sys.argv[1:]])
    for attempt in range(2):
        with tempfile.TemporaryDirectory(prefix='stillepost-start-') as temp:
            ack=pathlib.Path(temp)/'ready';env=dict(os.environ,STILLEPOST_STARTUP_ACK=str(ack))
            child=subprocess.Popen([str(bundle/'AppRun'),*sys.argv[1:]],env=env,start_new_session=True)
            deadline=time.monotonic()+15
            while time.monotonic()<deadline:
                if ack.exists():return 0
                status=child.poll()
                if status is not None:
                    if status==0:return 0 # Bestehende Instanz hat den Aufruf übernommen.
                    break
                time.sleep(.1)
            if child.poll() is None:
                child.terminate()
                try:child.wait(timeout=5)
                except subprocess.TimeoutExpired:child.kill();child.wait()
        if attempt==0:
            try:
                from update import Updater
                root=bundle.parent;Updater(bundle).rollback();bundle=(root/'current').resolve()
                continue
            except Exception:pass
        print('Stille Post konnte nicht starten. Diagnose: AppRun direkt starten.',file=sys.stderr)
        return 1
if __name__=='__main__':sys.exit(main())
