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
#ifndef COORDINATE_MAP_CPU_HPP
#define COORDINATE_MAP_CPU_HPP

#include "coordinate_map.hpp"

namespace minkowski {

/*
 * Inherit from the CoordinateMap for a specific map type.
 */
// clang-format off
template <typename coordinate_type,
          typename CoordinateAllocator = std::allocator<coordinate_type>>
class CoordinateMapCPU
    : public CoordinateMap<coordinate_type,
                           CoordinateUnorderedMap<coordinate_type>,
                           CoordinateAllocator> {
public:
  using base_type         = CoordinateMap<coordinate_type>;
  using size_type         = typename base_type::size_type;
  using key_type          = typename base_type::key_type;
  using mapped_type       = typename base_type::mapped_type;
  using value_type        = typename base_type::value_type;
  using index_type        = typename base_type::index_type;
  using iterator          = typename base_type::iterator;
  using const_iterator    = typename base_type::const_iterator;
  using index_vector_type = typename base_type::index_vector_type;
  // clang-format on

public:
  CoordinateMapCPU(size_type const coordinate_size)
      : base_type(coordinate_size) {}

  bool insert(key_type const &key, mapped_type const &val) {

    ASSERT(val < base_type::m_capacity, "Invalid mapped value: ", val,
           ", current capacity: ", base_type::m_capacity);
    coordinate_type *ptr =
        &base_type::m_coordinates[val * base_type::m_coordinate_size];
    std::copy_n(key.data(), base_type::m_coordinate_size, ptr);
    auto insert_result = base_type::m_map.insert(
        value_type(coordinate<coordinate_type>{ptr}, val));
    if (insert_result.second) {
      return true;
    } else {
      return false;
    }
  }

  /*
   * @brief given a key iterator begin-end pair and a value iterator begin-end
   * pair, insert all elements.
   *
   * @return none
   */
  template <typename key_iterator, typename mapped_iterator>
  void insert(key_iterator key_first, key_iterator key_last,
              mapped_iterator value_first, mapped_iterator value_last) {
    ASSERT(key_last - key_first == value_last - value_first,
           "The number of items mismatch. # of keys:", key_last - key_first,
           ", # of values:", value_last - value_first);
    // TODO: Batch coordinate copy
    base_type::allocate(key_last - key_first);
    for (; key_first != key_last; ++key_first, ++value_first) {
      // value_type ctor needed because this might be called with std::pair's
      insert(*key_first, *value_first);
    }
  }

  /*
   * redeclare the base find functions.
   */
  using base_type::find;

  /*
   * @brief given a key iterator begin-end pair find all valid keys and its
   * index.
   *
   * @return a pair of (valid index, query value) vectors.
   */
  template <typename key_iterator>
  std::pair<index_vector_type, index_vector_type> find(key_iterator key_first,
                                                       key_iterator key_last) {
    size_type N = key_last - key_first;
    ASSERT(N <= base_type::m_capacity,
           "Invalid search range. Current capacity:", base_type::m_capacity,
           ", search range:", N);

    // reserve the result slots
    index_vector_type valid_query_index, query_result;
    valid_query_index.reserve(N);
    query_result.reserve(N);

    key_iterator key_curr{key_first};
    for (; key_curr != key_last; ++key_curr) {
      auto const query_iter = base_type::find(*key_curr);
      // If valid query
      if (query_iter != base_type::end()) {
        valid_query_index.push_back(key_curr - key_first);
        query_result.push_back(query_iter->second);
      }
    }
    return std::make_pair(valid_query_index, query_result);
  }
};

} // namespace minkowski

#endif // COORDINATE_MAP_CPU
