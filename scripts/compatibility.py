"""Build a standalone schedule consumer with an explicitly selected Pascal compiler."""
import argparse
import json
import pathlib
import shutil
import subprocess
import tempfile


def classify(returncode, output, binary_exists):
    if 'does not support command line compiling' in output:
        return 'unavailable'
    if returncode != 0 or not binary_exists:
        return 'failed'
    return 'built'


def probe(compiler, kind, root):
    executable = shutil.which(compiler)
    if not executable:
        return dict(compiler=compiler, kind=kind, status='unavailable', reason='compiler not found')
    with tempfile.TemporaryDirectory(prefix='pascal core probe ') as temp:
        directory = pathlib.Path(temp)
        source = directory / 'CoreProbe.dpr'
        source.write_text('program CoreProbe;\n{$APPTYPE CONSOLE}\nuses SysUtils, FiberRuntime.Schedule;\n'
                          'var S:TPeriodicSchedule; T:TPeriodicTick;\nbegin\n'
                          'S:=TPeriodicSchedule.Create(0,1000);\n'
                          'if not S.TryAcquire(1000,T) then Halt(1);\n'
                          'S.Complete(3200);\nif S.NextDeadlineUs<>4000 then Halt(2);\n'
                          'S.Free; WriteLn(\'PASS CoreProbe\'); end.\n', encoding='utf-8')
        if kind == 'fpc':
            import os
            binary = directory / ('CoreProbe.exe' if os.name == 'nt' else 'CoreProbe')
            command = [executable, '-B', '-Mdelphi', '-Fu' + str(root / 'src'), '-FU' + temp, '-o' + str(binary), str(source)]
        else:
            binary = directory / 'CoreProbe.exe'
            command = [executable, '-B', '-Q', '-U' + str(root / 'src'), '-N0' + temp, '-E' + temp, str(source)]
        result = subprocess.run(command, cwd=directory, capture_output=True, text=True, timeout=60)
        status = classify(result.returncode, result.stdout + result.stderr, binary.is_file())
        if status == 'built':
            executed = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            status = 'passed' if executed.returncode == 0 and executed.stdout.strip() == 'PASS CoreProbe' else 'failed'
        return dict(compiler=compiler, kind=kind, status=status,
                    scope='standalone fixed-rate core only; no context/RTL certification',
                    reason='installed edition refuses CLI compilation' if status == 'unavailable' else None)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', default='fpc')
    parser.add_argument('--kind', choices=['fpc', 'delphi'], default='fpc')
    parser.add_argument('--out', type=pathlib.Path)
    args = parser.parse_args()
    result = probe(args.compiler, args.kind, pathlib.Path(__file__).resolve().parents[1])
    rendered = json.dumps(result, indent=2)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(rendered + '\n', encoding='utf-8')
    print(rendered)
    raise SystemExit(0 if result['status'] == 'passed' else 2)
