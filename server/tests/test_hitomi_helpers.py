import unittest

from server.vendor.kemono_dl.hitomi import collect_hitomi_names, pick_hitomi_directory_name


class HitomiHelpersTest(unittest.TestCase):
    def test_collect_hitomi_names_keeps_all_distinct_entries(self) -> None:
        info = {
            'artists': [
                {'artist': 'Artist A'},
                {'artist': 'Artist B'},
                {'artist': 'Artist A'},
                {'artist': '  Artist B  '},
            ]
        }

        self.assertEqual(
            collect_hitomi_names(info, 'artists', 'artist'),
            ['Artist A', 'Artist B'],
        )

    def test_collect_hitomi_names_supports_alternate_series_keys_and_fields(self) -> None:
        info = {
            'series': [
                {'name': 'Original Series'},
                {'title': 'Original Series'},
            ],
            'parody': {'series': 'Original Series'},
        }

        self.assertEqual(
            collect_hitomi_names(
                info,
                ('parodys', 'parodies', 'series', 'parody'),
                ('parody', 'series'),
            ),
            ['Original Series'],
        )

    def test_pick_hitomi_directory_name_prefers_series_for_multi_artist_gallery(self) -> None:
        self.assertEqual(
            pick_hitomi_directory_name(
                ['Artist A', 'Artist B'],
                [],
                ['Original Series'],
                'Sample Title',
            ),
            'Original Series',
        )

    def test_pick_hitomi_directory_name_avoids_artist_folder_when_multi_artist_has_no_series(self) -> None:
        self.assertEqual(
            pick_hitomi_directory_name(
                ['Artist A', 'Artist B'],
                [],
                [],
                'Sample Title',
            ),
            'Sample Title',
        )


if __name__ == '__main__':
    unittest.main()

