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
#include "kernel_region.hpp"
#include <omp.h>

namespace minkowski {

/*
 * Inherit from the CoordinateMap for a specific map type.
 */
// clang-format off
template <typename coordinate_type,
          template <typename T> class TemplatedAllocator = std::allocator>
class CoordinateMapCPU : public CoordinateMap<coordinate_type, TemplatedAllocator> {
public:
  using base_type                 = CoordinateMap<coordinate_type, TemplatedAllocator>;
  using self_type                 = CoordinateMapCPU<coordinate_type, TemplatedAllocator>;
  using size_type                 = typename base_type::size_type;
  using index_type                = typename base_type::index_type;
  using stride_type               = typename base_type::stride_type;

  using key_type       = coordinate<coordinate_type>;
  using mapped_type    = default_types::index_type;
  using hasher         = detail::coordinate_murmur3<coordinate_type>;
  using key_equal      = detail::coordinate_equal_to<coordinate_type>;
  using map_type       =
      robin_hood::unordered_flat_map<key_type,    // key
                                     mapped_type, // mapped_type
                                     hasher,      // hasher
                                     key_equal    // equality
                                     >;

  using value_type                = typename map_type::value_type;
  using iterator                  = typename map_type::iterator;
  using const_iterator            = typename map_type::const_iterator;

  using index_vector_type         = typename base_type::index_vector_type;
  using byte_allocator_type       = TemplatedAllocator<char>;
  // clang-format on

public:
  CoordinateMapCPU() = delete;
  CoordinateMapCPU(size_type const number_of_coordinates,
                   size_type const coordinate_size,
                   stride_type const &stride = {1},
                   byte_allocator_type alloc = byte_allocator_type())
      : base_type(number_of_coordinates, coordinate_size, stride, alloc),
        m_map(
            map_type{0, hasher{coordinate_size}, key_equal{coordinate_size}}) {
    m_map.reserve(number_of_coordinates);
  }

  /*
   * @brief given a key iterator begin-end pair and a value iterator begin-end
   * pair, insert all elements.
   *
   * @return none
   */
  void insert(coordinate_type const *coordinate_begin,
              coordinate_type const *coordinate_end) {
    size_type N = (coordinate_end - coordinate_begin) / m_coordinate_size;
    base_type::allocate(N);
    index_type value = 0;
    for (coordinate_type const *key = coordinate_begin; key != coordinate_end;
         key += m_coordinate_size, ++value) {
      // value_type ctor needed because this might be called with std::pair's
      insert(key_type(key), value);
    }
  }

  /*
   * @brief given a key iterator begin-end pair and a value iterator begin-end
   * pair, insert all elements.
   *
   * @return pair<vector<long>, vector<long>> if return_unique_inverse_map.
   * mapping is a vector of unique indices and inverse_mapping is a vector of
   * indices that reconstructs the original coordinate from the list of unique
   * coordinates.
   *
   * >>> unique_coordinates = input_coordinates[mapping]
   * >>> reconstructed_coordinates = unique_coordinates[inverse_mapping]
   * >>> torch.all(reconstructed_coordinates == input_coordinates)
   */
  template <bool remap>
  std::pair<std::vector<int64_t>, std::vector<int64_t>> // return maps
  insert_and_map(coordinate_type const *coordinate_begin,
                 coordinate_type const *coordinate_end) {
    size_type N = (coordinate_end - coordinate_begin) / m_coordinate_size;

    std::vector<int64_t> mapping, inverse_mapping;
    base_type::allocate(N);
    mapping.reserve(N);
    inverse_mapping.reserve(N);

    index_type value{0}, row_index{0};
    for (coordinate_type const *key = coordinate_begin; key != coordinate_end;
         key += m_coordinate_size, row_index += 1) {
      // value_type ctor needed because this might be called with std::pair's
      auto const result = insert(key_type(key), value);
      if (result.second) {
        mapping.push_back(row_index);
        inverse_mapping.push_back(value);
      } else {
        // result.first is an iterator of pair<key, mapped_type>
        inverse_mapping.push_back(result.first->second);
      }
      value += remap ? result.second : 1;
    }

    return std::make_pair(std::move(mapping), std::move(inverse_mapping));
  }

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
      auto const query_iter = m_map.find(*key_curr);
      // If valid query
      if (query_iter != m_map.end()) {
        valid_query_index.push_back(key_curr - key_first);
        query_result.push_back(query_iter->second);
      }
    }
    return std::make_pair(valid_query_index, query_result);
  }

  // Network specific functions.

  /*
   * @brief strided coordinate map.
   */
  self_type stride(stride_type const &stride) const {
    ASSERT(stride.size() == m_coordinate_size - 1, "Invalid stride", stride);
    // Over estimate the reserve size to be size();
    self_type stride_map(
        size(), m_coordinate_size,
        detail::stride_tensor_stride(base_type::m_tensor_stride, stride),
        base_type::m_byte_allocator);

    index_type c = 0;
    std::vector<coordinate_type> dst(m_coordinate_size);
    coordinate<coordinate_type> strided_coordinate(&dst[0]);
    for (auto const &kv : m_map) {
      detail::stride_coordinate<coordinate_type>(kv.first, dst,
                                                 stride_map.m_tensor_stride);
      auto result = stride_map.insert(strided_coordinate, c);
      LOG_DEBUG("Adding coordinate", dst, ":", c,
                "success:", (int)result.second);
      c += result.second;
    }

    return stride_map;
  }

  /*
   * @brief strided coordinate map for region.
   */
  self_type
  stride_region(cpu_kernel_region<coordinate_type> const &kernel) const {
    ASSERT(kernel.coordinate_size() == m_coordinate_size, "Invalid kernel");
    // Over estimate the reserve size to be size();
    stride_type out_tensor_stride(
        kernel.tensor_stride(), kernel.tensor_stride() + m_coordinate_size - 1);

    self_type stride_map(size() * kernel.volume(), m_coordinate_size,
                         out_tensor_stride, base_type::m_byte_allocator);

    auto &out_mmap = stride_map.m_map;

    auto ckernel = cpu_kernel_region<coordinate_type>(kernel);
    std::vector<coordinate_type> lb(m_coordinate_size), ub(m_coordinate_size),
        tmp(m_coordinate_size);

    index_type num_used{0};
    for (auto iter_in = m_map.begin(); iter_in != m_map.end(); ++iter_in) {

      // set the bounds for the current region
      ckernel.set_bounds(iter_in->first.data(), lb.data(), ub.data(),
                         tmp.data());

      // For elements in the current region
      for (const auto &point : ckernel) {
        // If the input coord exists
        const auto iter_out = out_mmap.find(point);
        // LOG_DEBUG(kernel_ind, ":",
        //           PtrToString(iter_out->first.data(), m_coordinate_size),
        //           "->", PtrToString(point.data(), m_coordinate_size));
        if (iter_out == out_mmap.end()) {
          insert(point, num_used);
          ++num_used;
        }
      }
    }
    return stride_map;
  }

  cpu_kernel_map
  kernel_map(self_type const &out_coordinate_map,
             cpu_kernel_region<coordinate_type> const &kernel) const {
    // Over estimate the reserve size to be size();
    size_type out_size = out_coordinate_map.size();
    size_type kernel_volume = kernel.volume();

    cpu_in_maps in_maps = initialize_maps<cpu_in_map>(kernel_volume, out_size);
    cpu_out_maps out_maps =
        initialize_maps<cpu_out_map>(kernel_volume, out_size);
    std::vector<size_type> num_used(kernel_volume);

    // OMP
    const auto &out_mmap = out_coordinate_map.m_map;
    const size_t out_map_num_elements = out_mmap.capacity();

    // size_t stride = max((size_t)100, numElements / (2 *
    // omp_get_max_threads())); size_t N = (numElements + stride - 1) /
    // stride;

    // compute the chunk size per thread.
    // There's a trade-off between the thread initialization overhead and the
    // job sizes. If some jobs finish earlier than others due to imbalance in
    // hash distribution, these threads will be idle.
    size_t N = 2 * omp_get_max_threads();
    const size_t stride = (out_map_num_elements + N - 1) / N;
    N = (out_map_num_elements + stride - 1) / stride;
    LOG_DEBUG("kernel map with", N, "chunks.");

    // When no need to iterate through the region
    // Put if outside the loop for speed
    if (kernel.region_type() != RegionType::CUSTOM && kernel_volume == 1) {
#pragma omp parallel for
      for (index_type n = 0; n < N; ++n) {
        index_type curr_index_begin;
        for (auto iter_out = out_mmap.begin(stride * n);
             iter_out.num_steps() <
             std::min(stride, out_map_num_elements - n * stride);
             ++iter_out) {

          const auto iter_in = m_map.find(iter_out->first);
          if (iter_in != m_map.end()) {
#pragma omp atomic capture
            {
              curr_index_begin = num_used[0];
              num_used[0] += 1;
            }

            in_maps[0][curr_index_begin] = iter_in->second;
            out_maps[0][curr_index_begin] = iter_out->second;
          }
        }
      }
    } else {
#pragma omp parallel for
      for (index_type n = 0; n < N; n++) {
        auto ckernel = cpu_kernel_region<coordinate_type>(kernel);
        // temporary variables for each thread
        std::vector<coordinate_type> lb(m_coordinate_size),
            ub(m_coordinate_size), tmp(m_coordinate_size);

        index_type kernel_ind, curr_index_begin;
        for (auto iter_out = out_mmap.begin(stride * n);
             iter_out.num_steps() <
             std::min(stride, out_map_num_elements - n * stride);
             ++iter_out) {

          // set the bounds for the current region
          ckernel.set_bounds(iter_out->first.data(), lb.data(), ub.data(),
                             tmp.data());

          // For elements in the current region
          kernel_ind = 0;
          for (const auto &point : ckernel) {
            // If the input coord exists
            const auto iter_in = m_map.find(point);
            // LOG_DEBUG(kernel_ind, ":",
            //           PtrToString(iter_out->first.data(), m_coordinate_size),
            //           "->", PtrToString(point.data(), m_coordinate_size));
            if (iter_in != m_map.end()) {
#pragma omp atomic capture
              {
                curr_index_begin = num_used[kernel_ind];
                num_used[kernel_ind] += 1;
              }
              // Ensure that in_maps and out_maps are resized accordingly
              in_maps[kernel_ind][curr_index_begin] = iter_in->second;
              out_maps[kernel_ind][curr_index_begin] = iter_out->second;
              // LOG_DEBUG(kernel_ind, ":",
              //           PtrToString(iter_in->first.data(),
              //           m_coordinate_size),
              //           "->",
              //           PtrToString(iter_out->first.data(),
              //           m_coordinate_size));
            }
            // Post processings
            kernel_ind++;
          }
        }
      }
    }

    for (index_type i = 0; i < kernel_volume; ++i) {
      index_type max_num = num_used[i];
      LOG_DEBUG("kernel index", i, "size:", max_num);
      in_maps[i].resize(max_num);
      out_maps[i].resize(max_num);
    }

    return std::make_pair(in_maps, out_maps);
  }

  cpu_kernel_map stride_map(self_type const &out_coordinate_map,
                            stride_type const &out_tensor_stride) const {
    // generate an in-out (kernel) map that maps all input points in the same
    // voxel to strided output voxel.
    size_type in_size = size();
    LOG_DEBUG("Generate stride_map with in NNZ:", in_size,
              "out NNZ:", out_coordinate_map.size(),
              "out_tensor_stride:", out_tensor_stride);
    ASSERT(in_size > out_coordinate_map.size(), "Invalid out_coordinate_map");
    cpu_in_maps in_maps = initialize_maps<cpu_in_map>(1, in_size);
    cpu_out_maps out_maps = initialize_maps<cpu_out_map>(1, in_size);

    // compute the chunk size per thread.
    // There's a trade-off between the thread initialization overhead and the
    // job sizes. If some jobs finish earlier than others due to imbalance in
    // hash distribution, these threads will be idle.
    const size_t in_map_num_elements = m_map.capacity();
    size_t N = 2 * omp_get_max_threads();
    const size_t stride = (in_map_num_elements + N - 1) / N;
    N = (in_map_num_elements + stride - 1) / stride;
    LOG_DEBUG("kernel map with", N, "chunks.");

    index_type num_used = 0;
#pragma omp parallel for
    for (index_type n = 0; n < N; ++n) {
      index_type curr_index_begin;
      std::vector<coordinate_type> dst(m_coordinate_size);
      for (auto iter_in = m_map.begin(stride * n);
           iter_in.num_steps() <
           std::min(stride, in_map_num_elements - n * stride);
           ++iter_in) {
        detail::stride_coordinate<coordinate_type>(iter_in->first, dst,
                                                   out_tensor_stride);
        const auto iter_out =
            out_coordinate_map.find(coordinate<coordinate_type>(dst.data()));
        ASSERT(iter_out != out_coordinate_map.m_map.cend(),
               "Invalid out_coordinate_map");
#pragma omp atomic capture
        {
          curr_index_begin = num_used;
          num_used += 1;
        }

        in_maps[0][curr_index_begin] = iter_in->second;
        out_maps[0][curr_index_begin] = iter_out->second;
      }
    }

    return std::make_pair(move(in_maps), move(out_maps));
  }

  inline size_type size() const noexcept { return m_map.size(); }
  std::string to_string() const {
    Formatter o;
    o << "CoordinateMapCPU:" << size() << "x" << m_coordinate_size;
    return o.str();
  }

  using base_type::capacity;
  using base_type::coordinate_size;
  using base_type::get_tensor_stride;

  inline void reserve(size_type c) {
    base_type::reserve(c);
    m_map.reserve(c);
  }

  void copy_coordinates(coordinate_type *dst_coordinate) const {
    size_t const capacity = m_map.capacity();
    size_t N = omp_get_max_threads();
    const size_t stride = (capacity + N - 1) / N;
    N = (capacity + stride - 1) / stride;
    LOG_DEBUG("kernel map with", N, "chunks, stride", stride, "capacity",
              capacity);

    // When no need to iterate through the region
    // Put if outside the loop for speed
#pragma omp parallel for
    for (index_type n = 0; n < N; ++n) {
      for (auto it = m_map.begin(stride * n);                        //
           it.num_steps() < std::min(stride, capacity - n * stride); //
           ++it) {
        std::copy_n(it->first.data(), m_coordinate_size,
                    dst_coordinate + m_coordinate_size * it->second);
      }
    }
  }

private:
  std::pair<iterator, bool> insert(key_type const &key,
                                   mapped_type const &val) {
    ASSERT(val < base_type::m_capacity, "Invalid mapped value: ", val,
           ", current capacity: ", base_type::m_capacity);
    coordinate_type *ptr = &base_type::m_coordinates[val * m_coordinate_size];
    std::copy_n(key.data(), m_coordinate_size, ptr);
    return m_map.insert(value_type(coordinate<coordinate_type>{ptr}, val));
  }

  inline iterator find(key_type const &key) { return m_map.find(key); }
  inline const_iterator find(key_type const &key) const {
    return m_map.find(key);
  }

private:
  using base_type::m_coordinate_size;
  map_type m_map;
}; // namespace minkowski

} // namespace minkowski

#endif // COORDINATE_MAP_CPU
