import unittest

from server.vendor.kemono_dl.hitomi import (
    build_hitomi_pdf_path,
    collect_hitomi_names,
    extract_hitomi_gallery_html_metadata,
    list_hitomi_extensions,
    pick_hitomi_directory_name,
    strip_hitomi_download_prefix,
)


class HitomiHelpersTest(unittest.TestCase):
    def test_gif_original_extension_is_preferred_in_auto_mode(self) -> None:
        extensions = list_hitomi_extensions(
            {
                "name": "sample.gif",
                "hasavif": True,
                "hasjxl": False,
            },
            preferred="auto",
        )

        self.assertEqual(extensions[0], "gif")

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

    def test_collect_hitomi_names_does_not_fallback_to_title_for_artist(self) -> None:
        info = {
            'artists': [
                {'title': '[20241105] [3114110] Sample Title'},
            ]
        }

        self.assertEqual(
            collect_hitomi_names(info, 'artists', ('artist', 'name')),
            [],
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
                ('parody', 'series', 'name', 'title'),
            ),
            ['Original Series'],
        )

    def test_extract_hitomi_gallery_html_metadata_reads_artists_and_series(self) -> None:
        html = '''
        <html>
          <body>
            <h2><a>Artist A</a> <a>Artist B</a></h2>
            <table>
              <tr><td>Group</td><td><a>Group X</a></td></tr>
              <tr><td>Series</td><td><a>Original Series</a></td></tr>
              <tr><td>Characters</td><td><a>Heroine</a></td></tr>
            </table>
          </body>
        </html>
        '''

        self.assertEqual(
            extract_hitomi_gallery_html_metadata(html),
            {
                'artists': ['Artist A', 'Artist B'],
                'groups': ['Group X'],
                'series': ['Original Series'],
                'characters': ['Heroine'],
            },
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

    def test_strip_hitomi_download_prefix_removes_date_and_post_id(self) -> None:
        self.assertEqual(
            strip_hitomi_download_prefix('[20241105] [3114110] Sample Title'),
            'Sample Title',
        )

    def test_build_hitomi_pdf_path_matches_generated_pdf_location(self) -> None:
        self.assertEqual(
            build_hitomi_pdf_path(
                r'C:\library\hitomi\Original Series [12345]',
                r'C:\library\hitomi\Original Series [12345]\[20241105] [3114110] Sample Title\001.webp',
            ),
            r'C:\library\hitomi\Original Series [12345]\Sample Title.pdf',
        )

    def test_list_hitomi_extensions_can_prefer_original_gif(self) -> None:
        self.assertEqual(
            list_hitomi_extensions(
                {'name': 'sample.gif', 'hasavif': True},
                preferred='original',
            )[0],
            'gif',
        )

    def test_list_hitomi_extensions_prefers_webp_fallback_for_original_gif(self) -> None:
        self.assertEqual(
            list_hitomi_extensions(
                {'name': 'sample.gif', 'hasavif': True},
                preferred='original',
            )[1],
            'webp',
        )


if __name__ == '__main__':
    unittest.main()
