"""Terminal and playlist-link regressions. Run: python3 -m unittest discover -s tests -v.

Requires installed bash, zsh, ffmpeg, ripit dependencies, and Python pexpect.
Uses generated audio and isolated shells; makes no network requests.
Pasted-URL quoting is a shell-wide concern and lives outside this repo
(~/.config/zsh/paste-url-quote.zsh), so it is not tested here.
"""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

import pexpect


ROOT = Path(__file__).resolve().parents[1]
MIX_URL = "https://www.youtube.com/watch?v=P_jcd-4grG0&list=RD6rIw54sYSQQ&index=5"


def ripit_fn(call):
    """Run one ripit.sh function in bash with the script sourced, return CompletedProcess."""
    script = 'source "$1" >/dev/null 2>&1; ' + call
    return subprocess.run(["bash", "-c", script, "test", str(ROOT / "ripit.sh")],
                          text=True, capture_output=True, stdin=subprocess.DEVNULL)


class PlaylistLinkTests(unittest.TestCase):
    def test_song_and_list_parsing(self):
        cases = [
            (MIX_URL, "P_jcd-4grG0 RD6rIw54sYSQQ"),
            ("https://music.youtube.com/watch?v=P_jcd-4grG0&list=PLabcdef", "P_jcd-4grG0 PLabcdef"),
            ("https://youtu.be/P_jcd-4grG0?list=OLAK5uy_xyz", "P_jcd-4grG0 OLAK5uy_xyz"),
            ("https://www.youtube.com/watch?list=PLabc&v=P_jcd-4grG0", "P_jcd-4grG0 PLabc"),
            ("https://www.youtube.com/watch?v=P_jcd-4grG0", None),          # plain song
            ("https://www.youtube.com/playlist?list=PLabc", None),          # playlist page
            ("https://soundcloud.com/x/sets/y?list=z&v=P_jcd-4grG0", None), # other site
        ]
        for url, want in cases:
            with self.subTest(url=url):
                r = ripit_fn("youtube_song_and_list " + shlex.quote(url))
                if want is None:
                    self.assertNotEqual(r.returncode, 0)
                    self.assertEqual(r.stdout, "")
                else:
                    self.assertEqual(r.returncode, 0)
                    self.assertEqual(r.stdout.strip(), want)

    def test_list_kind(self):
        for list_id, kind in [("RD6rIw54sYSQQ", "mix"), ("RDMM", "mix"), ("RDAMVMP_jcd-4grG0", "mix"),
                              ("RDCLAK5uy_abc", "playlist"), ("PLabc", "playlist"), ("OLAK5uy_x", "playlist")]:
            with self.subTest(list_id=list_id):
                self.assertEqual(ripit_fn("youtube_list_kind " + list_id).stdout.strip(), kind)

    def test_mix_offer_without_terminal_skips_and_explains(self):
        # stdin is not a tty here, so no prompt and no follow-up rip may start.
        r = ripit_fn("offer_playlist_rest " + shlex.quote(MIX_URL) + " RD6rIw54sYSQQ mix -o /nonexistent")
        self.assertEqual(r.returncode, 0)
        self.assertIn("endless", r.stdout)
        self.assertIn("ripit -p -n 25 '" + MIX_URL + "'", r.stdout)

    def test_mix_offer_at_terminal_honours_zero(self):
        child = pexpect.spawn("bash", ["-c", 'source "$1" >/dev/null 2>&1; offer_playlist_rest "$2" RDx mix; echo RC=$?',
                                       "test", str(ROOT / "ripit.sh"), MIX_URL],
                              encoding="utf-8", timeout=10, env={**os.environ, "TERM": "xterm"})
        self.addCleanup(child.close, force=True)
        child.expect_exact("Rip the next how many songs from this Mix? [0 = none]: ")
        child.sendline("0")
        child.expect_exact("Skipped.")
        child.expect_exact("RC=0")


class TerminalTests(unittest.TestCase):
    def shell(self):
        child = pexpect.spawn("zsh", ["-f"], encoding="utf-8", timeout=5,
                              env={**os.environ, "TERM": "xterm"})
        self.addCleanup(child.close, force=True)
        child.sendline("PROMPT='TEST> '; RPROMPT=''; unsetopt BEEP")
        child.expect_exact("TEST> ")
        return child

    def test_failed_analysis_rejects_partial_points(self):
        script = ('source "$1" >/dev/null 2>&1; '
                  'ffmpeg() { printf "silence_start: 1.25\\n" >&2; return 7; }; '
                  'detect_silence_points nonexistent.mp3 -30 1')
        result = subprocess.run(["bash", "-c", script, "test", str(ROOT / "ripit.sh")],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout, "")

    def test_background_silence_detection_finishes(self):
        with tempfile.TemporaryDirectory(prefix="ripit-terminal-") as tmp:
            audio = Path(tmp) / "silence.wav"
            subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi",
                            "-i", "anullsrc=r=8000:cl=mono", "-t", "2", str(audio)], check=True)
            result = Path(tmp) / "points"
            log = Path(tmp) / "log"
            script = (f"source {shlex.quote(str(ROOT / 'ripit.sh'))} >/dev/null 2>&1; "
                      f"detect_silence_points {shlex.quote(str(audio))} -30 1 "
                      f">{shlex.quote(str(result))} 2>{shlex.quote(str(log))}; "
                      "print_status=$?; printf 'DETECT_%s=%s\\n' DONE $print_status")
            child = self.shell()
            child.sendline("bash -c " + shlex.quote(script) + " &")
            try:
                child.expect_exact("DETECT_DONE=0\r\n")
                self.assertEqual(result.read_text().strip(), "0")
            finally:
                # Only jobs created in this disposable test shell.
                child.sendline("kill -KILL %1 2>/dev/null; exit")


if __name__ == "__main__":
    unittest.main()
