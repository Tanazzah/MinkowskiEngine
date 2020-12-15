import unittest
import torch
import MinkowskiEngineTest._C


class CoordinateMapTestCase(unittest.TestCase):
    def test_insert(self):
        coordinates = torch.IntTensor([[0, 1], [1, 2], [2, 3], [2, 3]])
        self.assertEqual(
            MinkowskiEngineTest._C.coordinate_map_insert_test(coordinates), 3
        )

    def test_batch_insert(self):
        coordinates = torch.IntTensor([[0, 1], [1, 2], [2, 3], [2, 3]])
        self.assertEqual(
            MinkowskiEngineTest._C.coordinate_map_batch_insert_test(coordinates), 3
        )

    def test_find(self):
        coordinates = torch.IntTensor([[0, 1], [1, 2], [2, 3], [2, 3]])
        queries = torch.IntTensor([[-1, 1], [1, 2], [2, 3], [2, 3], [0, 0]])
        query_results = MinkowskiEngineTest._C.coordinate_map_find_test(
            coordinates, queries
        )
        self.assertEqual(len(query_results), len(queries))
        self.assertEqual(query_results[1], 1)
        self.assertEqual(query_results[2], 2)
        self.assertEqual(query_results[3], 2)
        self.assertEqual(query_results[0], query_results[4])

    def test_batch_find(self):
        coordinates = torch.IntTensor([[0, 1], [1, 2], [2, 3], [2, 3]])
        queries = torch.IntTensor([[-1, 1], [1, 2], [2, 3], [2, 3], [0, 0]])
        valid_query_index, query_value = MinkowskiEngineTest._C.coordinate_map_batch_find_test(
            coordinates, queries
        )
        self.assertEqual(len(valid_query_index), len(query_value))
        self.assertEqual(len(valid_query_index), 3)

        self.assertEqual(valid_query_index[0], 1)
        self.assertEqual(valid_query_index[1], 2)
        self.assertEqual(valid_query_index[2], 3)

        self.assertEqual(query_value[0], 1)
        self.assertEqual(query_value[1], 2)
        self.assertEqual(query_value[2], 2)
