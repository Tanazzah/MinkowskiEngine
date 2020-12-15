/*
 * Copyright (c) 2020 NVIDIA CORPORATION.
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
#include "gpu.cuh"
#include "kernel_map.cuh"
#include "kernel_map.hpp"

#include <thrust/copy.h>
#include <thrust/device_vector.h>
#include <thrust/execution_policy.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/iterator/transform_iterator.h>
#include <thrust/sort.h>

namespace minkowski {

namespace detail {

template <typename coordinate_type, //
          typename size_type,       //
          typename index_type,      //
          typename map_type>
__global__ void
remap_inverse_map(map_type __restrict__ map,                       //
                  coordinate_type const *__restrict__ coordinates, //
                  index_type *__restrict__ inverse_map,            //
                  size_type const num_threads,                     //
                  size_type const coordinate_size                  //
) {
  auto const tx = threadIdx.x;
  auto const bx = blockIdx.x;
  auto const x = blockDim.x * bx + tx;

  if (x < num_threads) {
    auto result = map.find(
        coordinate<coordinate_type>{&coordinates[x * coordinate_size]});
    inverse_map[x] = result->second;
  }
}

template <typename coordinate_type, //
          typename size_type,       //
          typename index_type,      //
          typename map_type>
__global__ void
insert_and_map_kernel(map_type __restrict__ map,                       //
                      coordinate_type const *__restrict__ coordinates, //
                      index_type *__restrict__ valid_map_index,        //
                      // index_type *__restrict__ inverse_row_index,      //
                      index_type *__restrict__ valid_row_index, //
                      bool *__restrict__ success,               //
                      size_type const num_threads,              //
                      size_type const coordinate_size           //
) {
  auto const tx = threadIdx.x;
  auto const bx = blockIdx.x;
  auto const x = blockDim.x * bx + tx;

  if (x < num_threads) {
    // m_map.insert(pair);
    // Returns pair<iterator, (bool)insert_success>
    auto const result = map.insert(thrust::make_pair(
        coordinate<coordinate_type>{&coordinates[x * coordinate_size]}, x));

    // for unique_mapping. remove failed valid_row_index with success
    success[x] = result.second;
    valid_row_index[x] = x;
    // for inverse_mapping.
    // if (result.second)
    //   inverse_row_index[x] = x;
    // else {
    //   auto it = result.first;
    //   inverse_row_index[x] = it->second;
    // }
    // success map index. remove failed insertion with success.
    valid_map_index[x] = result.first.offset();
  }
}

} // namespace detail

/*
 * @brief Given a key iterator begin-end pair and a value iterator begin-end
 * pair, insert all elements.
 *
 * @note The key and value iterators can be 1) pointers, 2) coordinate or vector
 * iterators.
 *
 * @return none
 */
template <typename coordinate_type,
          template <typename T> class TemplatedAllocator>
template <bool remap>
void CoordinateMapGPU<coordinate_type, TemplatedAllocator>::insert(
    coordinate_iterator<coordinate_type> key_first,
    coordinate_iterator<coordinate_type> key_last) {
  size_type const N = key_last - key_first;
  LOG_DEBUG("key iterator length", N);

  // Copy the coordinates to m_coordinate
  base_type::reserve(N);
  CUDA_CHECK(
      cudaMemcpy(coordinate_data(), // dst
                 key_first->data(), // first element of the dereferenced iter.
                 sizeof(coordinate_type) * N * m_coordinate_size, // bytes
                 cudaMemcpyDeviceToDevice));
  CUDA_CHECK(cudaStreamSynchronize(0));
  LOG_DEBUG("Reserved and copied", N, "x", m_coordinate_size, "coordinates");

  //
  thrust::device_vector<bool> success(N);
  m_valid_row_index.resize(N);
  m_valid_map_index.resize(N);
  m_inverse_row_index.resize(N);

  // compute cuda kernel call params
  size_type const num_threads = N;
  size_type const num_blocks = GET_BLOCKS(num_threads, CUDA_NUM_THREADS);

  detail::insert_and_map_kernel<coordinate_type, size_type, index_type,
                                map_type><<<num_blocks, CUDA_NUM_THREADS>>>(
      *m_map, const_coordinate_data(),                    //
      thrust::raw_pointer_cast(m_valid_map_index.data()), //
      // thrust::raw_pointer_cast(m_inverse_row_index.data()), //
      thrust::raw_pointer_cast(m_valid_row_index.data()), //
      thrust::raw_pointer_cast(success.data()),           //
      num_threads, m_coordinate_size);
  CUDA_CHECK(cudaStreamSynchronize(0));

  // Valid row index
  auto valid_begin = thrust::make_zip_iterator(thrust::make_tuple(
      success.begin(), m_valid_row_index.begin(), m_valid_map_index.begin()));

  size_type const number_of_valid =
      thrust::remove_if(
          thrust::device, valid_begin,
          thrust::make_zip_iterator(thrust::make_tuple(
              success.end(), m_valid_row_index.end(), m_valid_map_index.end())),
          detail::is_first<bool>(false)) -
      valid_begin;

  m_valid_row_index.resize(number_of_valid);
  m_valid_map_index.resize(number_of_valid);
  m_size = number_of_valid;
  LOG_DEBUG("Number of successful insertion", m_size);

  if (remap                   // When remapping
      && number_of_valid != N // when the # of inserted items differ from the #
                              // of successful insertions
  ) {
    thrust::counting_iterator<uint32_t> count_begin{0};
    thrust::for_each(
        count_begin, count_begin + number_of_valid,
        detail::update_value_with_offset<index_type, map_type>{
            *m_map, thrust::raw_pointer_cast(m_valid_map_index.data())});

    size_type const num_threads = N;
    auto const num_blocks = GET_BLOCKS(num_threads, CUDA_NUM_THREADS);

    detail::remap_inverse_map<coordinate_type, size_type, index_type, map_type>
        <<<num_blocks, CUDA_NUM_THREADS>>>(
            *m_map,                                               //
            const_coordinate_data(),                              //
            thrust::raw_pointer_cast(m_inverse_row_index.data()), //
            num_threads, m_coordinate_size);

    LOG_DEBUG("Remapping finished");
  }
} // namespace minkowski

using return_vector_type = thrust::device_vector<default_types::index_type>;
template <typename coordinate_type,
          template <typename T> class TemplatedAllocator>
template <bool remap>
std::pair<return_vector_type, return_vector_type>
CoordinateMapGPU<coordinate_type, TemplatedAllocator>::insert_and_map(
    coordinate_iterator<coordinate_type> key_first,
    coordinate_iterator<coordinate_type> key_last) {
  LOG_DEBUG("insert_and_map");
  insert<remap>(key_first, key_last);
  return std::make_pair(m_valid_row_index, m_inverse_row_index);
}

/*
 * @brief given a key iterator begin-end pair find all valid keys and its
 * index.
 *
 * @return a pair of (valid index, query value) vectors.
 */
template <typename coordinate_type,
          template <typename T> class TemplatedAllocator>
std::pair<return_vector_type, return_vector_type>
CoordinateMapGPU<coordinate_type, TemplatedAllocator>::find(
    coordinate_iterator<coordinate_type> key_first,
    coordinate_iterator<coordinate_type> key_last) const {
  size_type N = key_last - key_first;

  LOG_DEBUG(N, "queries for find.");
  auto const find_functor = detail::find_coordinate<coordinate_type, map_type>(
      *m_map, key_first->data(), m_unused_element, m_coordinate_size);
  LOG_DEBUG("Find functor initialized.");
  auto const invalid_functor =
      detail::is_unused_pair<coordinate_type, mapped_type>(m_unused_element);
  LOG_DEBUG("Valid functor initialized.");

  thrust::counting_iterator<index_type> index{0};
  device_index_vector_type input_index(N);
  device_index_vector_type results(N);
  LOG_DEBUG("Initialized functors.");
  thrust::sequence(thrust::device, input_index.begin(), input_index.end());
  thrust::transform(thrust::device, index, index + N, results.begin(),
                    find_functor);

  size_type const number_of_valid =
      thrust::remove_if(thrust::device,
                        thrust::make_zip_iterator(thrust::make_tuple(
                            input_index.begin(), results.begin())),
                        thrust::make_zip_iterator(thrust::make_tuple(
                            input_index.end(), results.end())),
                        invalid_functor) -
      thrust::make_zip_iterator(
          thrust::make_tuple(input_index.begin(), results.begin()));
  LOG_DEBUG("Number of valid", number_of_valid);
  input_index.resize(number_of_valid);
  results.resize(number_of_valid);

  return std::make_pair(input_index, results);
}

namespace detail {

template <typename coordinate_type, //
          typename size_type,       //
          typename index_type>
__global__ void
stride_copy(coordinate_type const *__restrict__ src_coordinates, //
            index_type const *__restrict__ src_valid_row_index,  //
            size_type const *__restrict__ stride,                //
            coordinate_type *__restrict__ dst_coordinates,       //
            size_type const num_threads, size_type const coordinate_size) {
  extern __shared__ size_type sh_stride[];

  auto const tx = threadIdx.x;
  auto const bx = blockIdx.x;
  auto const x = blockDim.x * bx + tx;

  if (tx < coordinate_size - 1)
    sh_stride[tx] = stride[tx];

  if (x < num_threads) {
    const index_type src_start = src_valid_row_index[x] * coordinate_size;
    const index_type dst_start = x * coordinate_size;
    dst_coordinates[dst_start] = src_coordinates[src_start];
    for (index_type j = 1; j < coordinate_size; ++j) {
      dst_coordinates[dst_start + j] =
          (__float2int_rd(
              __fdiv_rd(src_coordinates[src_start + j], sh_stride[j - 1]))) *
          sh_stride[j - 1];
      // (__double2int_rd(
      //     __ddiv_rn(src_coordinates[src_start + j], sh_stride[j - 1]))) *
      // sh_stride[j - 1];
    }
  }
}

} // namespace detail

/*
 * @brief given a key iterator begin-end pair find all valid keys and its
 * index.
 *
 * @return a pair of (valid index, query value) vectors.
 */
template <typename coordinate_type,
          template <typename T> class TemplatedAllocator>
CoordinateMapGPU<coordinate_type, TemplatedAllocator>
CoordinateMapGPU<coordinate_type, TemplatedAllocator>::stride(
    stride_type const &stride) const {

  // Over estimate the reserve size to be size();
  size_type const N = size();
  LOG_DEBUG("Strided map with kernel stride:", stride);

  self_type stride_map(
      N, m_coordinate_size, m_hashtable_occupancy,
      detail::stride_tensor_stride(base_type::m_tensor_stride, stride),
      m_map_allocator, base_type::m_byte_allocator);

  // stride coordinates
  size_type const num_threads = N;
  auto const num_blocks = GET_BLOCKS(num_threads, CUDA_NUM_THREADS);

  detail::stride_copy<coordinate_type, size_type, index_type>
      <<<num_blocks, CUDA_NUM_THREADS, m_coordinate_size * sizeof(size_type)>>>(
          const_coordinate_data(),
          thrust::raw_pointer_cast(m_valid_row_index.data()),
          thrust::raw_pointer_cast(stride_map.m_device_tensor_stride.data()),
          stride_map.coordinate_data(), num_threads, m_coordinate_size);

  LOG_DEBUG("Stride copy done.");
  thrust::device_vector<bool> success(N);
  auto &stride_valid_row_index = stride_map.m_valid_row_index;
  auto &stride_valid_map_index = stride_map.m_valid_map_index;

  stride_valid_row_index.resize(N); // row indices
  stride_valid_map_index.resize(N); // map offset

  // Insert coordinates
  auto insert = detail::insert_coordinate<coordinate_type, map_type,
                                          index_type *>{
      *stride_map.m_map,                                       // map
      stride_map.const_coordinate_data(),                      // coordinates,
      thrust::raw_pointer_cast(stride_valid_row_index.data()), // valid row
      thrust::raw_pointer_cast(stride_valid_map_index.data()), // iter offset
      m_coordinate_size};
  thrust::counting_iterator<uint32_t> count_begin{0};
  thrust::transform(count_begin, count_begin + N, success.begin(), insert);
  LOG_DEBUG("Stride insertion done.");

  // Valid row index
  auto valid_begin = thrust::make_zip_iterator(
      thrust::make_tuple(success.begin(),                //
                         stride_valid_row_index.begin(), //
                         stride_valid_map_index.begin()));
  size_type const number_of_valid =
      thrust::remove_if(thrust::device, //
                        valid_begin,    //
                        thrust::make_zip_iterator(
                            thrust::make_tuple(success.end(),                //
                                               stride_valid_row_index.end(), //
                                               stride_valid_map_index.end())),
                        detail::is_first<bool>(false)) -
      valid_begin;
  stride_valid_row_index.resize(number_of_valid);
  stride_valid_map_index.resize(number_of_valid);
  stride_map.m_size = number_of_valid;
  LOG_DEBUG("Reduced to", number_of_valid);

  // remap values
  thrust::for_each(
      count_begin, count_begin + number_of_valid,
      detail::update_value_with_offset<index_type, map_type>{
          *stride_map.m_map,
          thrust::raw_pointer_cast(stride_map.m_valid_map_index.data())});

  LOG_DEBUG("Stride remap done");

  return stride_map;
}

namespace detail {

template <typename coordinate_type, //
          typename size_type,       //
          typename index_type,      //
          typename map_type>
__global__ void kernel_region_insert(
    map_type __restrict__ out_map,                              //
    coordinate_type const *const __restrict__ p_in_coordinates, //
    index_type const *const __restrict__ in_valid_row_index,    //
    coordinate_type *__restrict__ p_out_coordinates,            //
    index_type *__restrict__ out_valid_row_index,               //
    index_type *__restrict__ out_valid_map_index,               //
    size_type const num_threads,                                //
    gpu_kernel_region<coordinate_type> kernel,                  //
    index_type const unused_key) {                              //
  extern __shared__ coordinate_type sh_all[];

  auto const tx = threadIdx.x;
  auto const bx = blockIdx.x;
  auto const x = blockDim.x * bx + tx;

  size_type const coordinate_size = kernel.coordinate_size();
  size_type const volume = kernel.volume();

  // clang-format off
  size_type *sh_size = reinterpret_cast<size_type *>(sh_all);

  size_type *sh_tensor_stride = sh_size;
  size_type *sh_kernel_size   = sh_tensor_stride + coordinate_size;
  size_type *sh_dilation      = sh_kernel_size   + coordinate_size;

  coordinate_type *sh_coordinate = reinterpret_cast<coordinate_type *>(sh_dilation + coordinate_size);
  coordinate_type *sh_tmp = sh_coordinate +                   tx  * coordinate_size;
  coordinate_type *sh_lb  = sh_coordinate + (1 * blockDim.x + tx) * coordinate_size;
  coordinate_type *sh_ub  = sh_coordinate + (2 * blockDim.x + tx) * coordinate_size;
  // clang-format on

  for (index_type i = tx; i < coordinate_size - 1; i += blockDim.x) {
    sh_tensor_stride[i] = kernel.tensor_stride()[i];
    sh_kernel_size[i] = kernel.kernel_size()[i];
    sh_dilation[i] = kernel.dilation()[i];
  }

  __syncthreads();

  if (x < num_threads) {
    // iterate over values
    index_type out_index = x * volume;
    // set bounds for the valid keys
    kernel.set_bounds(
        &p_in_coordinates[in_valid_row_index[x] * coordinate_size], sh_lb,
        sh_ub, sh_tmp);
    for (auto const &curr_coordinate : kernel) {
      // initialize out coordinate
      for (uint32_t i = 0; i < coordinate_size; ++i)
        p_out_coordinates[out_index * coordinate_size + i] = curr_coordinate[i];

      auto const result = out_map.insert(thrust::make_pair(
          coordinate<coordinate_type>{
              &p_out_coordinates[out_index * coordinate_size]},
          out_index));

      if (result.second) {
        // row index in the out_coordinates
        out_valid_row_index[out_index] = x;
        // offset in the coordinate map
        out_valid_map_index[out_index] = result.first.offset();
      } else {
        out_valid_row_index[out_index] = unused_key;
      }
      ++out_index;
    }
  }
}

} // namespace detail

/*
 * @brief generate a region strided coordinate map
 *
 * @return a gpu_coordinate_map
 */
template <typename coordinate_type,
          template <typename T> class TemplatedAllocator>
CoordinateMapGPU<coordinate_type, TemplatedAllocator>
CoordinateMapGPU<coordinate_type, TemplatedAllocator>::stride_region(
    cpu_kernel_region<coordinate_type> &kernel,
    stride_type const &out_tensor_stride) const {

  ASSERT(m_coordinate_size == kernel.coordinate_size(),
         "Invalid kernel coordinate_size");
  gpu_kernel_region<coordinate_type> gpu_kernel(kernel.to_gpu());
  // Over estimate the reserve size to be size();
  size_type const N_in = size();
  size_type const N_out = N_in * kernel.volume();

  LOG_DEBUG("Stride region out tensor stride:", out_tensor_stride,
            "with capacity:", N_out);
  self_type stride_map(N_out, m_coordinate_size, m_hashtable_occupancy,
                       out_tensor_stride, m_map_allocator,
                       base_type::m_byte_allocator);

  auto &out_valid_row_index = stride_map.m_valid_row_index;
  auto &out_valid_map_index = stride_map.m_valid_map_index;

  out_valid_row_index.resize(N_out);
  out_valid_map_index.resize(N_out);

  index_type const unused_key = std::numeric_limits<index_type>::max();
  // (THREAD * 3 * D +  3 * D) * 4
  uint32_t const shared_memory_size_in_bytes =
      3 * m_coordinate_size * sizeof(index_type) + // stride, kernel, dilation
      3 * CUDA_NUM_THREADS * m_coordinate_size *
          sizeof(coordinate_type); // tmp, lb, ub

  detail::kernel_region_insert<coordinate_type, size_type, index_type, map_type>
      <<<GET_BLOCKS(N_in, CUDA_NUM_THREADS), CUDA_NUM_THREADS,
         shared_memory_size_in_bytes>>>(
          *stride_map.m_map,                                    //
          const_coordinate_data(),                              //
          thrust::raw_pointer_cast(m_valid_row_index.data()),   //
          stride_map.coordinate_data(),                         //
          thrust::raw_pointer_cast(out_valid_row_index.data()), //
          thrust::raw_pointer_cast(out_valid_map_index.data()), //
          N_in,                                                 //
          gpu_kernel,                                           //
          unused_key);                                          //
  CUDA_CHECK(cudaStreamSynchronize(0));
  LOG_DEBUG("kernel_region_insert done");
  LOG_DEBUG("valid row index", out_valid_row_index);
  LOG_DEBUG("valid map offset", out_valid_map_index);

  // remove unused_keys
  auto valid_begin = thrust::make_zip_iterator(
      thrust::make_tuple(out_valid_row_index.begin(), //
                         out_valid_map_index.begin()));
  size_type const number_of_valid =
      thrust::remove_if(thrust::device, //
                        valid_begin,    //
                        thrust::make_zip_iterator(
                            thrust::make_tuple(out_valid_row_index.end(), //
                                               out_valid_map_index.end())),
                        detail::is_first<index_type>(unused_key)) -
      valid_begin;
  out_valid_row_index.resize(number_of_valid);
  out_valid_map_index.resize(number_of_valid);
  stride_map.m_size = number_of_valid;
  LOG_DEBUG("Reduced to", number_of_valid);

  // remap values
  thrust::counting_iterator<index_type> count_begin{0};
  thrust::for_each(count_begin, count_begin + number_of_valid,
                   detail::update_value_with_offset<index_type, map_type>{
                       *stride_map.m_map,
                       thrust::raw_pointer_cast(out_valid_map_index.data())});
  LOG_DEBUG("Stride remap done");
  return stride_map;
}

namespace detail {

template <typename coordinate_type, typename size_type, typename index_type,
          bool stride_src>
__global__ void
copy_column_with_valid(coordinate_type *__restrict__ dst_coordinates,       //
                       size_type const num_threads,                         //
                       coordinate_type const *__restrict__ src_coordinates, //
                       index_type const *__restrict__ src_valid_row_index,  //
                       size_type const coordinate_size) {
  auto const tx = threadIdx.x;
  auto const bx = blockIdx.x;
  auto const x = blockDim.x * bx + tx;

  if (x < num_threads) {
    if (stride_src)
      dst_coordinates[x] =
          src_coordinates[src_valid_row_index[x] * coordinate_size];
    else
      dst_coordinates[x * coordinate_size] =
          src_coordinates[src_valid_row_index[x]];
  }
}

template <typename coordinate_type, typename size_type, bool stride_src>
__global__ void
copy_column(coordinate_type *__restrict__ dst_coordinates,       //
            size_type const num_threads,                         //
            coordinate_type const *__restrict__ src_coordinates, //
            size_type const coordinate_size) {
  auto const tx = threadIdx.x;
  auto const bx = blockIdx.x;
  auto const x = blockDim.x * bx + tx;

  if (x < num_threads) {
    if (stride_src)
      dst_coordinates[x] = src_coordinates[x * coordinate_size];
    else
      dst_coordinates[x * coordinate_size] = src_coordinates[x];
  }
}

} // namespace detail

template <typename coordinate_type,
          template <typename T> class TemplatedAllocator>
CoordinateMapGPU<coordinate_type, TemplatedAllocator>
CoordinateMapGPU<coordinate_type, TemplatedAllocator>::origin() const {
  size_type const N = size();
  LOG_DEBUG("Origin map from in map size:", N);

  // tensor stride is set to {0,..., 0} for the origin map.
  stride_type origin_tensor_stride(m_coordinate_size - 1);
  std::for_each(origin_tensor_stride.begin(), origin_tensor_stride.end(),
                [](auto &i) { i = 0; });

  // thrust unique for unique batch index
  coordinate_type *d_batch_indices = reinterpret_cast<coordinate_type *>(
      m_byte_allocator.allocate(N * sizeof(coordinate_type)));
  detail::copy_column_with_valid<coordinate_type, size_type, index_type, true>
      <<<GET_BLOCKS(N, CUDA_NUM_THREADS), CUDA_NUM_THREADS>>>(
          d_batch_indices, N, const_coordinate_data(),
          thrust::raw_pointer_cast(m_valid_row_index.data()),
          m_coordinate_size);

#ifdef DEBUG
  CUDA_CHECK(cudaStreamSynchronize(0));
  LOG_DEBUG("copied batch indices");
#endif

  // Sort and unique
  thrust::sort(thrust::device, d_batch_indices, d_batch_indices + N);
#ifdef DEBUG
  CUDA_CHECK(cudaStreamSynchronize(0));
  LOG_DEBUG("sorted batch indices");
#endif
  auto d_batch_indices_end =
      thrust::unique(thrust::device, d_batch_indices, d_batch_indices + N);
  size_type const N_unique = d_batch_indices_end - d_batch_indices;
#ifdef DEBUG
  size_t Nsize = std::min<int>(N, 100);
  std::vector<coordinate_type> tmp(Nsize);
  CUDA_CHECK(cudaMemcpy(tmp.data(), d_batch_indices,
                        Nsize * sizeof(coordinate_type),
                        cudaMemcpyDeviceToHost));
  LOG_DEBUG("sort and unique batch", tmp);
  CUDA_CHECK(cudaStreamSynchronize(0));
  LOG_DEBUG("unique done");
#endif

  // Create origin map
  LOG_DEBUG("Origin map with size:", N_unique,
            " tensor stride:", origin_tensor_stride);
  self_type origin_map(N_unique, m_coordinate_size, m_hashtable_occupancy,
                       origin_tensor_stride, m_map_allocator,
                       base_type::m_byte_allocator);
  CUDA_CHECK(
      cudaMemset(origin_map.coordinate_data(), 0,
                 N_unique * m_coordinate_size * sizeof(coordinate_type)));

  detail::copy_column<coordinate_type, size_type, false>
      <<<GET_BLOCKS(N_unique, CUDA_NUM_THREADS), CUDA_NUM_THREADS>>>(
          origin_map.coordinate_data(), N_unique, d_batch_indices,
          m_coordinate_size);

#ifdef DEBUG
  CUDA_CHECK(cudaStreamSynchronize(0));
  LOG_DEBUG("copied batch indices to the origin_map");
#endif

  auto &origin_valid_row_index = origin_map.m_valid_row_index;
  auto &origin_valid_map_index = origin_map.m_valid_map_index;

  origin_valid_row_index.resize(N_unique);
  origin_valid_map_index.resize(N_unique);
  origin_map.m_size = N_unique;

  // Insert coordinates
  auto insert = detail::insert_coordinate<coordinate_type, map_type,
                                          index_type *>{
      *origin_map.m_map,                                       // map
      origin_map.const_coordinate_data(),                      // coordinates,
      thrust::raw_pointer_cast(origin_valid_row_index.data()), // valid row
      thrust::raw_pointer_cast(origin_valid_map_index.data()), // iter offset
      m_coordinate_size};

  thrust::counting_iterator<uint32_t> count_begin{0};
  thrust::for_each(thrust::device, count_begin, count_begin + N_unique, insert);

#ifdef DEBUG
  CUDA_CHECK(cudaStreamSynchronize(0));
  LOG_DEBUG("origin map insertion");
#endif

  m_byte_allocator.deallocate((char *)d_batch_indices,
                              N * sizeof(coordinate_type));

  return origin_map;
}

namespace detail {

template <typename coordinate_type, //
          typename size_type,       //
          typename index_type,      //
          typename map_type>
__global__ void prune_copy_and_insert(
    size_type const num_threads,                              //
    size_type const coordinate_size,                          //
    index_type const unused_map_offset,                       //
    index_type const *const __restrict__ in_valid_row_index,  //
    coordinate_type const *const __restrict__ in_coordinates, //
    bool const *const __restrict__ keep_begin,                //
    index_type const *const __restrict__ inclusive_scan_keep, //
    map_type __restrict__ out_map,                            //
    coordinate_type *__restrict__ out_coordinates,            //
    index_type *__restrict__ out_valid_row_index,             //
    index_type *__restrict__ out_valid_map_offset             //
) {
  auto const tx = threadIdx.x;
  auto const bx = blockIdx.x;
  auto const x = blockDim.x * bx + tx;

  if (x < num_threads) {
    auto out_row_index = (x < 1) ? 0 : inclusive_scan_keep[x - 1];
    coordinate_type const *curr_in_coord =
        &in_coordinates[in_valid_row_index[x] * coordinate_size];
    coordinate_type *curr_out_coord =
        &out_coordinates[out_row_index * coordinate_size];
    for (index_type i = 0; i < coordinate_size; ++i)
      curr_out_coord[i] = curr_in_coord[i];

    // insert to the out_map
    auto coord = coordinate<coordinate_type>{curr_out_coord};
    // remap the value in the next kernel call
    auto result = out_map.insert(thrust::make_pair(coord, 0));
    out_valid_row_index[x] = x;
    if (result.second)
      out_valid_map_offset[x] = result.first.offset();
    else
      out_valid_map_offset[x] = unused_map_offset;
  }
}

template <typename coordinate_type, //
          typename size_type,       //
          typename index_type,      //
          typename map_type>
__global__ void remap(size_type const num_threads,                  //
                      map_type const __restrict__ out_map,          //
                      index_type *__restrict__ out_valid_map_offset //
) {
  auto const tx = threadIdx.x;
  auto const bx = blockIdx.x;
  auto const x = blockDim.x * bx + tx;

  if (x < num_threads) {
    auto &pair = out_map.data()[out_valid_map_offset[x]];
    pair.second = x;
  }
}

template <typename Dtype, typename Stype>
__global__ void typed_copy(uint32_t const num_threads,   //
                           Dtype *__restrict__ dst,      //
                           Stype const *__restrict__ src //
) {
  auto const tx = threadIdx.x;
  auto const bx = blockIdx.x;
  auto const x = blockDim.x * bx + tx;

  if (x < num_threads) {
    dst[x] = src[x];
  }
}

} // namespace detail

template <typename coordinate_type,
          template <typename T> class TemplatedAllocator>
CoordinateMapGPU<coordinate_type, TemplatedAllocator>
CoordinateMapGPU<coordinate_type, TemplatedAllocator>::prune(
    bool const *keep_begin, bool const *keep_end) const {
  size_type const N = size();
  ASSERT(N == keep_end - keep_begin, "Invalid keep size");
  LOG_DEBUG("Prune size:", N);

  // exclusive sum for coordinate copy.
  auto const inclusive_scan_size = N * sizeof(index_type);
  index_type *d_inclusive_scan =
      (index_type *)m_byte_allocator.allocate(inclusive_scan_size);
  // bool -> index_type
  detail::typed_copy<<<GET_BLOCKS(N, CUDA_NUM_THREADS), CUDA_NUM_THREADS>>>(
      N, d_inclusive_scan, keep_begin);
  CUDA_CHECK(cudaStreamSynchronize(0));
  thrust::inclusive_scan(thrust::device, d_inclusive_scan, d_inclusive_scan + N,
                         d_inclusive_scan);
  index_type N_pruned;
  CUDA_CHECK(cudaMemcpy(&N_pruned, d_inclusive_scan + N - 1, sizeof(index_type),
                        cudaMemcpyDeviceToHost));
  LOG_DEBUG("Pruned N:", N_pruned);

  // create a coordinate_map
  self_type pruned_map(N_pruned, m_coordinate_size, m_hashtable_occupancy,
                       base_type::m_tensor_stride, m_map_allocator,
                       base_type::m_byte_allocator);

  // Copy and insert kernel that first checks keep[i] is true and insert at
  // inclusive_scan[i - 1].
  auto &out_valid_map_offset = pruned_map.m_valid_map_index;
  auto &out_valid_row_index = pruned_map.m_valid_row_index;
  out_valid_map_offset.resize(N);
  out_valid_row_index.resize(N);

  index_type const unused_map_offset = std::numeric_limits<index_type>::max();
  detail::prune_copy_and_insert<coordinate_type, size_type, index_type,
                                map_type>
      <<<GET_BLOCKS(N, CUDA_NUM_THREADS), CUDA_NUM_THREADS>>>(
          N, m_coordinate_size, unused_map_offset,
          thrust::raw_pointer_cast(m_valid_row_index.data()),
          const_coordinate_data(), keep_begin, d_inclusive_scan,
          *(pruned_map.m_map), pruned_map.coordinate_data(),
          thrust::raw_pointer_cast(out_valid_row_index.data()),
          thrust::raw_pointer_cast(out_valid_map_offset.data()));
  CUDA_CHECK(cudaStreamSynchronize(0));

  // Remove not inserted rows
  auto valid_begin = thrust::make_zip_iterator(thrust::make_tuple(
      out_valid_map_offset.begin(), out_valid_row_index.begin()));
  size_type const number_of_valid =
      thrust::remove_if(
          thrust::device, valid_begin,
          thrust::make_zip_iterator(thrust::make_tuple(
              out_valid_map_offset.end(), out_valid_row_index.end())),
          detail::is_first<index_type>(unused_map_offset)) -
      valid_begin;

  out_valid_map_offset.resize(number_of_valid);
  out_valid_row_index.resize(number_of_valid);

  pruned_map.m_size = number_of_valid;

  // remap the final map values
  detail::remap<coordinate_type, size_type, index_type, map_type>
      <<<GET_BLOCKS(number_of_valid, CUDA_NUM_THREADS), CUDA_NUM_THREADS>>>(
          number_of_valid, *(pruned_map.m_map),
          thrust::raw_pointer_cast(out_valid_map_offset.data()));
  CUDA_CHECK(cudaStreamSynchronize(0));

  m_byte_allocator.deallocate((char *)d_inclusive_scan, inclusive_scan_size);

  return pruned_map;
}

namespace detail {

template <typename coordinate_type, //
          typename size_type,       //
          typename index_type,      //
          typename map_type>
__global__ void
count_kernel(map_type const __restrict__ in_map,                       //
             map_type const __restrict__ out_map,                      //
             index_type const *const __restrict__ out_valid_map_index, //
             size_type const num_threads,                              //
             gpu_kernel_region<coordinate_type> kernel,                //
             index_type *__restrict__ p_count_per_thread) {
  extern __shared__ coordinate_type sh_all[];

  auto const tx = threadIdx.x;
  auto const bx = blockIdx.x;
  auto const x = blockDim.x * bx + tx;

  size_type const coordinate_size = kernel.coordinate_size();
  size_type const volume = kernel.volume();

  // clang-format off
  size_type *sh_size = reinterpret_cast<size_type *>(sh_all);

  size_type *sh_tensor_stride = sh_size;
  size_type *sh_kernel_size   = sh_tensor_stride + coordinate_size;
  size_type *sh_dilation      = sh_kernel_size   + coordinate_size;

  coordinate_type *sh_coordinate = reinterpret_cast<coordinate_type *>(sh_dilation + coordinate_size);
  coordinate_type *sh_tmp = sh_coordinate +                   tx  * coordinate_size;
  coordinate_type *sh_lb  = sh_coordinate + (1 * blockDim.x + tx) * coordinate_size;
  coordinate_type *sh_ub  = sh_coordinate + (2 * blockDim.x + tx) * coordinate_size;
  // clang-format on

  auto const equal = out_map.get_key_equal();

  // kernel_maps
  for (index_type i = tx; i < coordinate_size - 1; i += blockDim.x) {
    sh_tensor_stride[i] = kernel.tensor_stride()[i];
    sh_kernel_size[i] = kernel.kernel_size()[i];
    sh_dilation[i] = kernel.dilation()[i];
  }

  __syncthreads();

  auto const unused_key = out_map.get_unused_key();
  if (x < num_threads) {
    size_type count = 0;
    typename map_type::value_type const &out_value =
        out_map.data()[out_valid_map_index[x]];
    // valid_index guarantees that it contains a valid value
    if (!equal(out_value.first, unused_key)) {
      // set bounds for the valid keys
      kernel.set_bounds(out_value.first.data(), sh_lb, sh_ub, sh_tmp);
      for (auto const &coordinate : kernel) {
        if (in_map.find(coordinate) != in_map.end()) {
          ++count;
        }
      }
    }
    p_count_per_thread[x] = count;
  }
}

template <typename coordinate_type, //
          typename size_type,       //
          typename index_type,      //
          typename map_type>
__global__ void preallocated_kernel_map_iteration(
    map_type const __restrict__ in_map,                                     //
    map_type const __restrict__ out_map,                                    //
    index_type const *const __restrict__ out_valid_map_index,               //
    size_type const num_threads,                                            //
    gpu_kernel_region<coordinate_type> kernel,                              //
    index_type const *const __restrict__ inclusive_count_cumsum_per_thread, //
    index_type *__restrict__ p_kernels,                                     //
    index_type *__restrict__ p_in_maps,                                     //
    index_type *__restrict__ p_out_maps) {
  extern __shared__ coordinate_type sh_all[];

  auto const tx = threadIdx.x;
  auto const bx = blockIdx.x;
  auto const x = blockDim.x * bx + tx;

  size_type const coordinate_size = kernel.coordinate_size();
  size_type const volume = kernel.volume();

  // clang-format off
  size_type *sh_size = reinterpret_cast<size_type *>(sh_all);

  size_type *sh_tensor_stride = sh_size;
  size_type *sh_kernel_size   = sh_tensor_stride + coordinate_size;
  size_type *sh_dilation      = sh_kernel_size   + coordinate_size;

  coordinate_type *sh_coordinate = reinterpret_cast<coordinate_type *>(sh_dilation + coordinate_size);
  coordinate_type *sh_tmp = sh_coordinate +                   tx  * coordinate_size;
  coordinate_type *sh_lb  = sh_coordinate + (1 * blockDim.x + tx) * coordinate_size;
  coordinate_type *sh_ub  = sh_coordinate + (2 * blockDim.x + tx) * coordinate_size;
  // clang-format on

  auto const equal = out_map.get_key_equal();

  for (index_type i = tx; i < coordinate_size - 1; i += blockDim.x) {
    sh_tensor_stride[i] = kernel.tensor_stride()[i];
    sh_kernel_size[i] = kernel.kernel_size()[i];
    sh_dilation[i] = kernel.dilation()[i];
  }

  __syncthreads();

  auto const unused_key = out_map.get_unused_key();
  if (x < num_threads) {
    // iterate over values
    auto kernel_map_index =
        (x < 1) ? 0 : inclusive_count_cumsum_per_thread[x - 1];
    index_type kernel_index = 0;
    typename map_type::value_type const &out_value =
        out_map.data()[out_valid_map_index[x]];
    if (!equal(out_value.first, unused_key)) {
      // set bounds for the valid keys
      kernel.set_bounds(out_value.first.data(), sh_lb, sh_ub, sh_tmp);
      kernel_index = 0;
      for (auto const &coordinate : kernel) {
        auto const &in_result = in_map.find(coordinate);
        if (in_result != in_map.end()) {
          // insert to
          p_kernels[kernel_map_index] = kernel_index;
          p_in_maps[kernel_map_index] = (*in_result).second;
          p_out_maps[kernel_map_index] = out_value.second;
          ++kernel_map_index;
        }
        ++kernel_index;
      }
    }
  }
}

template <typename coordinate_type, //
          typename size_type,       //
          typename index_type,      //
          typename map_type>
__global__ void
direct_in_out_map(size_type const num_threads,                               //
                  map_type const __restrict__ in_map,                        //
                  map_type const __restrict__ out_map,                       //
                  index_type const *const __restrict__ out_valid_map_offset, //
                  index_type *__restrict__ p_in_maps,                        //
                  index_type *__restrict__ p_out_maps,
                  index_type const unused_key) {
  auto const tx = threadIdx.x;
  auto const bx = blockIdx.x;
  auto const x = blockDim.x * bx + tx;

  if (x < num_threads) {
    typename map_type::value_type const &out_value =
        out_map.data()[out_valid_map_offset[x]];
    auto const &result = in_map.find(out_value.first);
    if (result != in_map.end()) {
      p_in_maps[x] = (*result).second;
      p_out_maps[x] = out_value.second;
    } else {
      p_in_maps[x] = unused_key;
    }
  }
}

} // namespace detail

template <typename coordinate_type,
          template <typename T> class TemplatedAllocator>
CoordinateMapGPU<coordinate_type, TemplatedAllocator>::kernel_map_type
CoordinateMapGPU<coordinate_type, TemplatedAllocator>::kernel_map(
    self_type const &out_map, gpu_kernel_region<coordinate_type> const &kernel,
    CUDAKernelMapMode::Mode kernel_map_mode, uint32_t thread_dim) const {
  // Over estimate the reserve size to be size();
  size_type const out_size = out_map.size();
  size_type const kernel_volume = kernel.volume();

  if (kernel_volume > 1 && kernel.region_type() != RegionType::CUSTOM) {
    // clang-format off
  // (THREAD * 3 * D +  3 * D) * 4
  uint32_t const shared_memory_size_in_bytes =
      3 * m_coordinate_size * sizeof(index_type) + // stride, kernel, dilation
      3 * thread_dim * m_coordinate_size * sizeof(coordinate_type); // tmp, lb, ub
    // clang-format on
    size_type const num_threads = out_size;
    auto const num_blocks = GET_BLOCKS(num_threads, thread_dim);

    LOG_DEBUG("num block", num_blocks);
    LOG_DEBUG("out_map size", out_map.size());
    LOG_DEBUG("shared_memory size", shared_memory_size_in_bytes);
    LOG_DEBUG("threads dim", thread_dim);
    LOG_DEBUG("num threads", num_threads);

    index_type *d_p_count_per_thread = reinterpret_cast<index_type *>(
        base_type::m_byte_allocator.allocate(num_threads * sizeof(index_type)));

    // Initialize count per thread
    detail::count_kernel<coordinate_type, size_type, index_type, map_type>
        <<<num_blocks, thread_dim, shared_memory_size_in_bytes>>>(
            *m_map,                                                     //
            *out_map.m_map,                                             //
            thrust::raw_pointer_cast(out_map.m_valid_map_index.data()), //
            num_threads,                                                //
            kernel,                                                     //
            d_p_count_per_thread);
    CUDA_CHECK(cudaStreamSynchronize(0));
    LOG_DEBUG("count_kernel finished");

    thrust::inclusive_scan(thrust::device, d_p_count_per_thread,
                           d_p_count_per_thread + num_threads,
                           d_p_count_per_thread);

    index_type num_kernel_map; // type following the kernel map allocator
    CUDA_CHECK(cudaMemcpy(&num_kernel_map,
                          d_p_count_per_thread + num_threads - 1,
                          sizeof(index_type), cudaMemcpyDeviceToHost));

    // set kernel map
    LOG_DEBUG("Found", num_kernel_map, "kernel map elements.");

    kernel_map_type kernel_map(num_kernel_map, base_type::m_byte_allocator);
    CUDA_CHECK(cudaStreamSynchronize(0));
    LOG_DEBUG("Allocated kernel_map.");

    detail::preallocated_kernel_map_iteration<coordinate_type, size_type,
                                              index_type, map_type>
        <<<num_blocks, thread_dim, shared_memory_size_in_bytes>>>(
            *m_map,                                                     //
            *out_map.m_map,                                             //
            thrust::raw_pointer_cast(out_map.m_valid_map_index.data()), //
            num_threads,                                                //
            kernel,                                                     //
            d_p_count_per_thread,                                       //
            kernel_map.kernels.begin(),                                 //
            kernel_map.in_maps.begin(),                                 //
            kernel_map.out_maps.begin());

    CUDA_CHECK(cudaStreamSynchronize(0));
    LOG_DEBUG("Preallocated kernel map done");

    kernel_map.decompose();
    base_type::m_byte_allocator.deallocate(
        reinterpret_cast<char *>(d_p_count_per_thread),
        num_threads * sizeof(index_type));
    LOG_DEBUG("cudaFree");

    return kernel_map;
  } else { // kernel volume == 1
    ASSERT(kernel_volume == 1, "Invalid kernel volume:", kernel_volume);
    // directly iterate over all output first by finding all in out map.
    auto const N = out_map.size();

    LOG_DEBUG("out_map size:", N);
    index_type *in_out_map = (index_type *)base_type::m_byte_allocator.allocate(
        2 * (N + 1) * sizeof(index_type));
    index_type *ins = in_out_map;
    index_type *outs =
        in_out_map + N + 1; // for __restrict__ collision prevention

    index_type unused_key = std::numeric_limits<index_type>::max();
    detail::direct_in_out_map<coordinate_type, size_type, index_type, map_type>
        <<<GET_BLOCKS(N, thread_dim), thread_dim>>>(
            N, *m_map,                                                  //
            *(out_map.m_map),                                           //
            thrust::raw_pointer_cast(out_map.m_valid_map_index.data()), //
            ins,  // in map
            outs, // out map
            unused_key);

    LOG_DEBUG("Direct in out map copy done");
    auto begin = thrust::make_zip_iterator(thrust::make_tuple(ins, outs));
    auto const valid_size =
        thrust::remove_if(
            thrust::device, begin,
            thrust::make_zip_iterator(thrust::make_tuple(ins + N, outs + N)),
            detail::is_first<index_type>(unused_key)) -
        begin;
    LOG_DEBUG("Valid size:", valid_size);

    kernel_map_type kernel_map(valid_size, base_type::m_byte_allocator, false);
    CUDA_CHECK(cudaMemcpy(kernel_map.in_maps.data(), ins,
                          valid_size * sizeof(index_type),
                          cudaMemcpyDeviceToDevice));
    CUDA_CHECK(cudaMemcpy(kernel_map.out_maps.data(), outs,
                          valid_size * sizeof(index_type),
                          cudaMemcpyDeviceToDevice));

    base_type::m_byte_allocator.deallocate((char *)in_out_map,
                                           2 * (N + 1) * sizeof(index_type));
    LOG_DEBUG("Cleaning up");
    return kernel_map;
  }
}

namespace detail {

template <typename coordinate_type, //
          typename size_type,       //
          typename index_type,      //
          typename map_type>
__global__ void
stride_map_kernel(map_type const __restrict__ in_map,                      //
                  map_type const __restrict__ out_map,                     //
                  index_type const *const __restrict__ in_valid_map_index, //
                  size_type const num_threads,                             //
                  index_type const *const __restrict__ stride,             //
                  index_type *__restrict__ p_in_maps,                      //
                  index_type *__restrict__ p_out_maps,
                  size_type const coordinate_size) {
  extern __shared__ coordinate_type sh_all[];

  auto const tx = threadIdx.x;
  auto const bx = blockIdx.x;
  auto const x = blockDim.x * bx + tx;

  // clang-format off
  size_type *sh_size = reinterpret_cast<size_type *>(sh_all);

  size_type *sh_stride = sh_size;

  coordinate_type *sh_coordinate = reinterpret_cast<coordinate_type *>(sh_size + coordinate_size);
  coordinate_type *sh_tmp = sh_coordinate + tx * coordinate_size;
  // clang-format on

  for (index_type i = tx; i < coordinate_size - 1; i += blockDim.x) {
    sh_stride[i] = stride[i];
  }

  __syncthreads();

  if (x >= num_threads)
    return;

  typename map_type::value_type const &in_value =
      in_map.data()[in_valid_map_index[x]];

  sh_tmp[0] = in_value.first[0];
  for (index_type j = 1; j < coordinate_size; ++j) {
    sh_tmp[j] =
        (__float2int_rd(__fdiv_rd(in_value.first[j], sh_stride[j - 1]))) *
        sh_stride[j - 1];
  }

  auto out_iter = out_map.find(coordinate<coordinate_type>(sh_tmp));

  p_in_maps[x] = in_value.second;
  p_out_maps[x] = out_iter->second;
}

} // namespace detail

template <typename coordinate_type,
          template <typename T> class TemplatedAllocator>
CoordinateMapGPU<coordinate_type, TemplatedAllocator>::kernel_map_type
CoordinateMapGPU<coordinate_type, TemplatedAllocator>::stride_map(
    self_type const &out_map, stride_type const &out_tensor_stride,
    uint32_t thread_dim) const {
  // Over estimate the reserve size to be size();
  size_type const in_size = size();
  thrust::device_vector<size_type> d_out_tensor_stride(
      out_tensor_stride.begin(), out_tensor_stride.end());

  // (THREAD * D +  D) * 4
  uint32_t const shared_memory_size_in_bytes =
      m_coordinate_size * sizeof(index_type) +                  // stride
      thread_dim * m_coordinate_size * sizeof(coordinate_type); // tmp
  size_type const num_threads = in_size;
  auto const num_blocks = GET_BLOCKS(num_threads, thread_dim);

  LOG_DEBUG("num block", num_blocks);
  LOG_DEBUG("shared_memory size", shared_memory_size_in_bytes);
  LOG_DEBUG("threads dim", thread_dim);
  LOG_DEBUG("num threads", num_threads);

  kernel_map_type kernel_map(in_size, base_type::m_byte_allocator,
                             false /* reserve_kernel_index */);
  CUDA_CHECK(cudaStreamSynchronize(0));
  LOG_DEBUG("Allocated kernel_map.");

  detail::stride_map_kernel<coordinate_type, size_type, index_type, map_type>
      <<<num_blocks, thread_dim, shared_memory_size_in_bytes>>>(
          *m_map,                                               //
          *out_map.m_map,                                       //
          thrust::raw_pointer_cast(m_valid_map_index.data()),   //
          num_threads,                                          //
          thrust::raw_pointer_cast(d_out_tensor_stride.data()), //
          kernel_map.in_maps.begin(),                           //
          kernel_map.out_maps.begin(),                          //
          m_coordinate_size);

  return kernel_map;
}

namespace detail {

template <typename coordinate_type, //
          typename size_type,       //
          typename index_type,      //
          typename map_type>
__global__ void
origin_map_kernel(map_type const __restrict__ in_map,                      //
                  map_type const __restrict__ origin_map,                  //
                  index_type const *const __restrict__ in_valid_map_index, //
                  size_type const num_threads,                             //
                  index_type *__restrict__ p_in_maps,                      //
                  index_type *__restrict__ p_out_maps,
                  index_type *__restrict__ p_kernels,
                  size_type const coordinate_size) {
  extern __shared__ coordinate_type sh_all[];

  auto const tx = threadIdx.x;
  auto const bx = blockIdx.x;
  auto const x = blockDim.x * bx + tx;

  // clang-format off
  coordinate_type *sh_tmp = sh_all + tx * coordinate_size;
  // clang-format on

  if (x < num_threads)
    for (index_type i = 0; i < coordinate_size; ++i)
      sh_tmp[i] = 0;

  __syncthreads();

  if (x < num_threads) {
    typename map_type::value_type const &in_value =
        in_map.data()[in_valid_map_index[x]];

    sh_tmp[0] = in_value.first[0];
    auto origin_iter = origin_map.find(coordinate<coordinate_type>(sh_tmp));

    p_in_maps[x] = in_value.second;
    p_out_maps[x] = origin_iter->second; // origin_map row index
    // For kernel_map decompose()
    p_kernels[x] = origin_iter->second;
  }
}

} // namespace detail

template <typename coordinate_type,
          template <typename T> class TemplatedAllocator>
CoordinateMapGPU<coordinate_type, TemplatedAllocator>::kernel_map_type
CoordinateMapGPU<coordinate_type, TemplatedAllocator>::origin_map(
    self_type const &origin_map, uint32_t thread_dim) const {
  ASSERT(std::all_of(origin_map.get_tensor_stride().begin(),
                     origin_map.get_tensor_stride().end(),
                     [](auto const &i) { return i == 0; }),
         "Invalid origin tensor stride", origin_map.get_tensor_stride());

  // reserve size();
  size_type const in_size = size();
  LOG_DEBUG("in_map size:", in_size, "origin_map size:", origin_map.size());
  // (THREAD * D) * 4
  uint32_t const shared_memory_size_in_bytes =
      thread_dim * m_coordinate_size * sizeof(coordinate_type); // tmp
  size_type const num_threads = in_size;
  auto const num_blocks = GET_BLOCKS(num_threads, thread_dim);

  LOG_DEBUG("origin_map num block", num_blocks);
  LOG_DEBUG("origin_map shared_memory size", shared_memory_size_in_bytes);
  LOG_DEBUG("origin_map threads dim", thread_dim);
  LOG_DEBUG("origin_map num threads", num_threads);

  kernel_map_type kernel_map(in_size, base_type::m_byte_allocator);
  CUDA_CHECK(cudaStreamSynchronize(0));
  LOG_DEBUG("Allocated kernel_map.");

  detail::origin_map_kernel<coordinate_type, size_type, index_type, map_type>
      <<<num_blocks, thread_dim, shared_memory_size_in_bytes>>>(
          *m_map,                                             //
          *origin_map.m_map,                                  //
          thrust::raw_pointer_cast(m_valid_map_index.data()), //
          num_threads,                                        //
          kernel_map.in_maps.begin(),                         //
          kernel_map.out_maps.begin(),                        //
          kernel_map.kernels.begin(),                         //
          m_coordinate_size);

  CUDA_CHECK(cudaStreamSynchronize(0));
  kernel_map.decompose();
  LOG_DEBUG("origin map decomposed");

  return kernel_map;
}

namespace detail {

template <typename coordinate_type, //
          typename size_type,       //
          typename index_type,      //
          typename map_type>
__global__ void copy_coordinates(map_type __restrict__ map,                  //
                                 coordinate_type *__restrict__ coordinates,  //
                                 index_type const *__restrict__ map_offsets, //
                                 size_type const num_threads,                //
                                 size_type const coordinate_size             //
) {
  auto const tx = threadIdx.x;
  auto const bx = blockIdx.x;
  auto const x = blockDim.x * bx + tx;

  if (x < num_threads) {
    typename map_type::value_type const *p_value = map.data() + map_offsets[x];
    // Compute Capabilities 3.5 or newer
    coordinate_type *dst_coordinate =
        coordinates + p_value->second * coordinate_size;
    for (index_type i = 0; i < coordinate_size; ++i)
      dst_coordinate[i] = p_value->first[i];
  }
}

} // namespace detail

// Helper functions
template <typename coordinate_type,
          template <typename T> class TemplatedAllocator>
void CoordinateMapGPU<coordinate_type, TemplatedAllocator>::copy_coordinates(
    coordinate_type *dst_coordinate) const {

  size_type const num_threads = size();
  if (num_threads > 0) {
    size_type const num_blocks = GET_BLOCKS(num_threads, CUDA_NUM_THREADS);

    detail::copy_coordinates<coordinate_type, size_type, index_type, map_type>
        <<<num_blocks, CUDA_NUM_THREADS>>>(
            *m_map,                                             //
            dst_coordinate,                                     //
            thrust::raw_pointer_cast(m_valid_map_index.data()), //
            num_threads,                                        //
            m_coordinate_size);
  }
}

// Template instantiation
template class CoordinatesGPU<default_types::dcoordinate_type,
                              detail::default_allocator>;
template class CoordinatesGPU<default_types::dcoordinate_type,
                              detail::c10_allocator>;
template class CoordinatesGPU<default_types::ccoordinate_type,
                              detail::default_allocator>;
template class CoordinatesGPU<default_types::ccoordinate_type,
                              detail::c10_allocator>;

template class CoordinateMapGPU<default_types::dcoordinate_type,
                                detail::default_allocator>;
template class CoordinateMapGPU<default_types::dcoordinate_type,
                                detail::c10_allocator>;

template std::pair<return_vector_type, return_vector_type>
CoordinateMapGPU<default_types::dcoordinate_type, detail::default_allocator>::
    insert_and_map<true>(
        coordinate_iterator<default_types::dcoordinate_type> key_first,
        coordinate_iterator<default_types::dcoordinate_type> key_last);

template std::pair<return_vector_type, return_vector_type>
CoordinateMapGPU<default_types::dcoordinate_type, detail::default_allocator>::
    insert_and_map<false>(
        coordinate_iterator<default_types::dcoordinate_type> key_first,
        coordinate_iterator<default_types::dcoordinate_type> key_last);

template std::pair<return_vector_type, return_vector_type>
CoordinateMapGPU<default_types::dcoordinate_type, detail::c10_allocator>::
    insert_and_map<true>(
        coordinate_iterator<default_types::dcoordinate_type> key_first,
        coordinate_iterator<default_types::dcoordinate_type> key_last);

template std::pair<return_vector_type, return_vector_type>
CoordinateMapGPU<default_types::dcoordinate_type, detail::c10_allocator>::
    insert_and_map<false>(
        coordinate_iterator<default_types::dcoordinate_type> key_first,
        coordinate_iterator<default_types::dcoordinate_type> key_last);

} // namespace minkowski
