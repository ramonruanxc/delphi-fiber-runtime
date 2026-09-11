"""Build and run QuickStart from a clone or Boss-installed library on this host."""
import argparse
import pathlib
import subprocess
import sys

from context_build import build_native

ROOT = pathlib.Path(__file__).resolve().parents[1]
MARKER = 'PASS: QuickStart services and managed events stopped cleanly'


def build_example(library, out, compiler='fpc'):
    library, out = pathlib.Path(library).resolve(), pathlib.Path(out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    version = subprocess.check_output([compiler, '-iV'], text=True, timeout=15).strip()
    if version != '3.2.2':
        raise ValueError('QuickStart requires a qualified FPC 3.2.2 context backend')
    native = build_native(out / 'native', root=library, run_tests=False)
    binary = out / ('QuickStart.exe' if sys.platform == 'win32' else 'QuickStart')
    binary.unlink(missing_ok=True)
    command = [compiler, '-B', '-Mdelphi', '-Sa', '-Cr', '-Co', '-Ct', '-O2',
               '-Fu' + str(library / 'src'), '-Fl' + str(native), '-FU' + str(out),
               '-o' + str(binary), str(library / 'demo/QuickStart.dpr')]
    compiled = subprocess.run(command, cwd=out, capture_output=True, text=True, timeout=60)
    (out / 'compile.log').write_text(compiled.stdout + compiled.stderr, encoding='utf-8')
    if compiled.returncode or not binary.is_file():
        raise RuntimeError('QuickStart compile failed; see ' + str(out / 'compile.log'))
    run = subprocess.run([str(binary)], cwd=out, capture_output=True, text=True, timeout=30)
    output = run.stdout + run.stderr
    (out / 'run.log').write_text(output, encoding='utf-8')
    if run.returncode or MARKER not in output:
        raise RuntimeError('QuickStart execution failed: ' + output)
    print(output.strip())
    return binary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=pathlib.Path, default=ROOT)
    parser.add_argument('--out', type=pathlib.Path, default=pathlib.Path('build/quickstart'))
    parser.add_argument('--fpc', default='fpc')
    args = parser.parse_args()
    build_example(args.library, args.out, args.fpc)
