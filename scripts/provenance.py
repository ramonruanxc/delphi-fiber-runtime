"""Reject tracked edits and nonignored untracked inputs in verified builds."""
import subprocess


def dirty(root):
    return bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=root, text=True).strip())
