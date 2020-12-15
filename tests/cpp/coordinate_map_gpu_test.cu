/* Copyright (c) 2020 NVIDIA CORPORATION.
 * Copyright (c) 2018-2020 Chris Choy (chrischoy@ai.stanford.edu)
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 * IN THE SOFTWARE.
 *
 * Please cite "4D Spatio-Temporal ConvNets: Minkowski Convolutional Neural
 * Networks", CVPR'19 (https://arxiv.org/abs/1904.08755) if you use any part
 * of the code.
 */
#include "coordinate_map_functors.cuh"
#include "coordinate_map_gpu.cuh"
#include "types.hpp"
#include "utils.hpp"

#include <thrust/device_vector.h>
#include <thrust/for_each.h>
#include <thrust/host_vector.h>

#include <torch/extension.h>

namespace minkowski {

using coordinate_type = int32_t;
using index_type = default_types::index_type;
using size_type = default_types::size_type;

size_type coordinate_map_batch_insert_test(const torch::Tensor &coordinates) {
  // Create TensorArgs. These record the names and positions of each tensor as a
  // parameter.
  torch::TensorArg arg_coordinates(coordinates, "coordinates", 0);

  torch::CheckedFrom c = "coordinate_test";
  torch::checkContiguous(c, arg_coordinates);
  // must match coordinate_type
  torch::checkScalarType(c, arg_coordinates, torch::kInt);
  torch::checkBackend(c, arg_coordinates.tensor, torch::Backend::CUDA);
  torch::checkDim(c, arg_coordinates, 2);

  auto const N = (index_type)coordinates.size(0);
  auto const D = (index_type)coordinates.size(1);
  coordinate_type const *d_ptr = coordinates.data_ptr<coordinate_type>();

  LOG_DEBUG("Initialize a GPU map.");
  CoordinateMapGPU<coordinate_type> map{N, D};

  auto input_coordinates = coordinate_range<coordinate_type>(N, D, d_ptr);
  thrust::counting_iterator<uint32_t> iter{0};

  LOG_DEBUG("Insert coordinates");
  map.insert(input_coordinates.begin(), // key begin
             input_coordinates.end(),   // key end
             iter,                      // value begin
             iter + N);                 // value end

  return map.size();
}

std::pair<std::vector<index_type>, std::vector<index_type>>
coordinate_map_batch_find_test(const torch::Tensor &coordinates,
                               const torch::Tensor &queries) {
  // Create TensorArgs. These record the names and positions of each tensor as a
  // parameter.
  torch::TensorArg arg_coordinates(coordinates, "coordinates", 0);
  torch::TensorArg arg_queries(queries, "queries", 1);

  torch::CheckedFrom c = "coordinate_test";
  torch::checkContiguous(c, arg_coordinates);
  torch::checkContiguous(c, arg_queries);

  // must match coordinate_type
  torch::checkScalarType(c, arg_coordinates, torch::kInt);
  torch::checkScalarType(c, arg_queries, torch::kInt);
  torch::checkBackend(c, arg_coordinates.tensor, torch::Backend::CUDA);
  torch::checkBackend(c, arg_queries.tensor, torch::Backend::CUDA);
  torch::checkDim(c, arg_coordinates, 2);
  torch::checkDim(c, arg_queries, 2);

  auto const N = (index_type)coordinates.size(0);
  auto const D = (index_type)coordinates.size(1);
  auto const NQ = (index_type)queries.size(0);
  auto const DQ = (index_type)queries.size(1);

  ASSERT(D == DQ, "Coordinates and queries must have the same size.");
  coordinate_type const *ptr = coordinates.data_ptr<coordinate_type>();
  coordinate_type const *query_ptr = queries.data_ptr<coordinate_type>();

  CoordinateMapGPU<coordinate_type> map{N, D};

  auto input_coordinates = coordinate_range<coordinate_type>(N, D, ptr);
  thrust::counting_iterator<uint32_t> iter{0};

  map.insert(input_coordinates.begin(), // key begin
             input_coordinates.end(),   // key end
             iter,                      // value begin
             iter + N);                 // value end

  LOG_DEBUG("Map size", map.size());
  auto query_coordinates = coordinate_range<coordinate_type>(NQ, D, query_ptr);

  LOG_DEBUG("Find coordinates.");
  auto const query_results =
      map.find(query_coordinates.begin(), query_coordinates.end());
  auto const &firsts(query_results.first);
  auto const &seconds(query_results.second);
  index_type NR = firsts.size();
  LOG_DEBUG(NR, "keys found.");

  std::vector<index_type> cpu_firsts(NR);
  std::vector<index_type> cpu_seconds(NR);

  thrust::copy(firsts.begin(), firsts.end(), cpu_firsts.begin());
  thrust::copy(seconds.begin(), seconds.end(), cpu_seconds.begin());
  return std::make_pair(cpu_firsts, cpu_seconds);
}

} // namespace minkowski

PYBIND11_MODULE(TORCH_EXTENSION_NAME, m) {
  m.def("coordinate_map_batch_insert_test",
        &minkowski::coordinate_map_batch_insert_test,
        "Minkowski Engine coordinate map batch insert test");

  m.def("coordinate_map_batch_find_test",
        &minkowski::coordinate_map_batch_find_test,
        "Minkowski Engine coordinate map batch find test");
}
