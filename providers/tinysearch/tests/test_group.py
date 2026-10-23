import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import group

def r(title, seeds=50, grade='g'):
    return {'title': title, 'seeds': seeds, 'quality': 1080, 'tv_ok': True, 'dv5': False, 'ua': False, 'audio': [],
            'size_gb': 5, 'category': '', 'grade': grade}

class Group(unittest.TestCase):
    def test_same_film_different_releases_one_card(self):
        w = group.works([r('Дюна: Часть вторая / Dune: Part Two (2024) WEB-DL 2160p'), r('Dune.Part.Two.2024.1080p.WEB'),
                         r('Dune (2021) 1080p BluRay', 300)])
        keys = {x['title']: x['count'] for x in w}
        self.assertEqual(keys.get('Dune: Part Two'), 2); self.assertEqual(keys.get('Dune'), 1)
        self.assertEqual([x['year'] for x in w if x['title'] == 'Dune: Part Two'], ['2024'])

    def test_multi_language_title_uses_latin_part(self):   # real job Dune Part Two
        w = group.works([r('Дюна: Часть вторая / Дюна: Частина друга / Dune: Part Two (2024) TS 1080p | UKR'),
                         r('Дюна: Часть вторая / Dune: Part Two (2024) WEB-DL 2160p')])
        self.assertEqual([(x['title'], x['count']) for x in w], [('Dune: Part Two', 2)])

    def test_leading_tags_and_cd_count(self):   # real job Pink Floyd flac
        w = group.works([r('(Progressive Rock) [CD] Pink Floyd - The Dark Side Of The Moon (1973) FLAC'),
                         r('Pink Floyd - The Dark Side Of The Moon (1973) (PBTHAL LP 24-96 FLAC)'),
                         r('Pink Floyd - Wish You Were Here 50 3xCD (2025) FLAC'),
                         r('Pink Floyd - Wish You Were Here 50 (2025 Rock) [Flac 24-192]')])
        self.assertEqual(sorted((x['title'], x['count']) for x in w),
                         [('Pink Floyd - The Dark Side Of The Moon', 2), ('Pink Floyd - Wish You Were Here 50', 2)])

    def test_game_updates_and_yearless_fold(self):   # real job Elden Ring; games carry no video quality (tsearch gives 0)
        g = lambda t: dict(r(t), quality=0, tv_ok=False)
        w = group.works([g('ELDEN RING [FitGirl Repack]'), g('ELDEN RING (2022)'),
                         g('ELDEN RING v.1.16 (2022)'), g('ELDEN RING - Update Only v1.03.1 (Require ELDEN RING v1.03)'),
                         g('Elden Ring: Deluxe Edition [v 1.16.1] (2022) PC | RePack')])
        self.assertEqual({(x['title'].lower(), x['kind']) for x in w}, {('elden ring', 'game'), ('elden ring: deluxe edition', 'game')})
        self.assertEqual(sum(x['count'] for x in w if x['title'] == 'ELDEN RING'), 4)


class SoundtrackDoesNotFlipFilm(unittest.TestCase):
    def test_film_card_keeps_kind_and_ost_gets_own_card(self):
        rows = [dict(r('Дюна: Часть вторая / Dune: Part Two (2024) WEB-DL 2160p', 50 + i)) for i in range(40)]
        ost = dict(r('(Score) [CD] Дюна: Часть вторая / Dune: Part Two (Original Motion Picture Soundtrack) (2024) FLAC', 20))
        ost['quality'] = 0; ost['category'] = 'Music'
        w = group.works(rows + [ost])
        kinds = sorted((x['kind'], x['count']) for x in w)
        self.assertEqual(kinds, [('film', 40), ('music', 1)])
        film = next(x for x in w if x['kind'] == 'film')
        self.assertNotIn('Score', film['best']['title'])
