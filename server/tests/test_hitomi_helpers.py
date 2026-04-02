import unittest

from server.vendor.kemono_dl.hitomi import (
    build_hitomi_pdf_path,
    collect_hitomi_names,
    pick_hitomi_directory_name,
)


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

    def test_build_hitomi_pdf_path_matches_generated_pdf_location(self) -> None:
        self.assertEqual(
            build_hitomi_pdf_path(
                r'C:\library\hitomi\Original Series [12345]',
                r'C:\library\hitomi\Original Series [12345]\[20241105] [3114110] Sample Title\001.webp',
            ),
            r'C:\library\hitomi\Original Series [12345]\[20241105] [3114110] Sample Title.pdf',
        )


if __name__ == '__main__':
    unittest.main()
