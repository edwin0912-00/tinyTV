import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import picker

def r(title, seeds=50, q=1080, tv=True, dv5=False, ua=False, size=10, cat='', grade='g'):
    return {'title': title, 'seeds': seeds, 'quality': q, 'tv_ok': tv, 'dv5': dv5, 'ua': ua, 'audio': ['UA'] if ua else [],
            'size_gb': size, 'category': cat, 'grade': grade}

class Picker(unittest.TestCase):
    def test_kind(self):
        self.assertEqual(picker.kind(r('Pink Floyd - The Wall (1979) FLAC', cat='Music')), 'music')
        self.assertEqual(picker.kind(r('Breaking Bad S02 1080p')), 'series')
        self.assertEqual(picker.kind(r('Холлис Джеймс - Под тенью Сатурна', cat='Психотерапия (книги)')), 'book')
        self.assertEqual(picker.kind(r('ELDEN RING [FitGirl Repack]', cat='Games')), 'game')
        self.assertEqual(picker.kind(r('Dune Part Two 2024 2160p')), 'film')

    def test_film_prefers_tv_ok_and_ua_over_raw_seeds(self):
        rows = [r('Dune 2160p DV', 300, 2160, tv=False, dv5=True), r('Dune 1080p UA', 60, ua=True), r('Dune 1080p', 80)]
        self.assertEqual(picker.best(rows, 'film')['title'], 'Dune 1080p UA')

    def test_prefer_small(self):
        rows = [r('A 2160p', 80, 2160, size=60), r('A 1080p', 70, size=8)]
        self.assertEqual(picker.best(rows, 'film', 'small')['title'], 'A 1080p')

    def test_music_prefers_flac(self):
        rows = [r('X mp3 320', 200, 0, cat='Music'), r('X FLAC', 40, 0, cat='Music')]
        self.assertEqual(picker.best(rows, 'music')['title'], 'X FLAC')

    def test_red_grade_last(self):
        self.assertEqual(picker.best([r('a', 2, grade='r'), r('b', 30)], 'film')['title'], 'b')

    def test_repack_in_video_release_is_film(self):   # real job Dune Part Two
        self.assertEqual(picker.kind(r('Dune Part Two 2024 REPACK 4K HDR DV 2160p BDRemux x265', cat='Movies')), 'film')
        self.assertEqual(picker.kind(r('Dune.Part.Two.2024.REPACK.2160p.AMZN.WEB-DL.DDP5.1')), 'film')
