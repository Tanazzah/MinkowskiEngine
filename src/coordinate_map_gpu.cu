/* Copyright (c) 2020 NVIDIA CORPORATION.
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
#include "gpu.cuh"

namespace minkowski {

/*
 * @brief Given a key iterator begin-end pair and a value iterator begin-end
 * pair, insert all elements.
 *
 * @note The key and value iterators can be 1) pointers, 2) coordinate or vector
 * iterators.
 *
 * @return none
 */
template <typename coordinate_type, typename MapAllocator,
          typename CoordinateAllocator>
template <typename key_iterator, typename mapped_iterator>
void CoordinateMapGPU<coordinate_type, MapAllocator,
                      CoordinateAllocator>::insert(key_iterator key_first,
                                                   key_iterator key_last,
                                                   mapped_iterator value_first,
                                                   mapped_iterator value_last) {
  using self_type =
      CoordinateMapGPU<coordinate_type, MapAllocator, CoordinateAllocator>;

  self_type::size_type N = key_last - key_first;
  ASSERT(N == value_last - value_first,
         "The number of items mismatch. # of keys:", N,
         ", # of values:", value_last - value_first);

  // Copy the coordinates to m_coordinate
  self_type::base_type::reserve(N);
  CUDA_CHECK(
      cudaMemcpy(self_type::base_type::m_coordinate.get() /* dst */,
                 &key_first[0] /* src */,
                 sizeof(coordinate_type) * std::is_pointer<key_iterator>::value
                     ? N * m_coordinate_size
                     : N /* n */,
                 cudaMemcpyDeviceToDevice));
  // CUDA_CHECK(cudaStreamSynchronize(0));

  thrust::counting_iterator<uint32_t> count{0};
  thrust::for_each(count, count + N,
                   insert_coordinate<coordinate_type, self_type::map_type>{
                       self_type::base_type::m_map,
                       self::base_type::m_coordinate.get(), value_first,
                       self_type::base_type::m_coordinate_size});
}

/*
 * @brief given a key iterator begin-end pair find all valid keys and its
 * index.
 *
 * @return a pair of (valid index, query value) vectors.
 */
// template <typename coordinate_type, typename MapAllocator,
//           typename CoordinateAllocator>
// template <typename key_iterator>
// std::pair<device_index_vector_type, device_index_vector_type>
// CoordinateMapGPU<coordinate_type, MapAllocator, CoordinateAllocator>::find(
//     key_iterator key_first, key_iterator key_last) {
//   size_type N = key_last - key_first;
//   ASSERT(N <= base_type::m_capacity,
//          "Invalid search range. Current capacity:", base_type::m_capacity,
//          ", search range:", N);
// 
//   // reserve the result slots
//   index_vector_type valid_query_index, query_result;
//   valid_query_index.reserve(N);
//   query_result.reserve(N);
// 
//   key_iterator key_curr{key_first};
//   for (; key_curr != key_last; ++key_curr) {
//     auto const query_iter = base_type::find(*key_curr);
//     // If valid query
//     if (query_iter != base_type::end()) {
//       valid_query_index.push_back(key_curr - key_first);
//       query_result.push_back(query_iter->second);
//     }
//   }
//   return std::make_pair(valid_query_index, query_result);
// }

// Template instantiation
template class CoordinateMapGPU<int32_t>;
template<> CoordinateMapGPU<int32_t>::insert<int32_t*, uint32_t*>;
} // namespace minkowski

#endif // COORDINATE_MAP_CPU
