"""Compare existing files by identity, independent of Windows 8.3 path spelling."""
import os


def assert_same_files(test, actual, expected):
    actual = list(actual)
    remaining = list(expected)
    test.assertEqual(len(actual), len(remaining), 'Different number of selected files')
    for path in actual:
        index = next((i for i, candidate in enumerate(remaining) if os.path.samefile(path, candidate)), None)
        test.assertIsNotNone(index, f'Unexpected staged file: {path}')
        remaining.pop(index)
