import unittest

import numpy as np

from app import app


class GenerationJSONTests(unittest.TestCase):
    def test_nested_band_diagnostics_keep_native_values(self):
        result = {'parts': [{'stats': {'valid': np.bool_(True),
                  'notes': np.int64(58), 'confidence': np.float32(.75)}}],
                  'onsets': np.array([0., .25]), 'available': False}
        with app.app_context():
            response = app.json.response(result)
            self.assertEqual(response.status_code, 200)
            decoded = response.get_json()
        self.assertIs(decoded['parts'][0]['stats']['valid'], True)
        self.assertEqual(decoded['parts'][0]['stats']['notes'], 58)
        self.assertEqual(decoded['parts'][0]['stats']['confidence'], .75)
        self.assertEqual(decoded['onsets'], [0., .25])
        self.assertIs(decoded['available'], False)

    def test_unknown_objects_still_fail_instead_of_becoming_strings(self):
        with self.assertRaises(TypeError):
            app.json.dumps({'unexpected': object()})


if __name__ == '__main__':
    unittest.main()
