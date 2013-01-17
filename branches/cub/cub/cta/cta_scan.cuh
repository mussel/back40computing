/******************************************************************************
 * 
 * Copyright (c) 2010-2012, Duane Merrill.  All rights reserved.
 * Copyright (c) 2011-2012, NVIDIA CORPORATION.  All rights reserved.
 * 
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License. 
 * 
 ******************************************************************************/

/**
 * \file
 * The cub::CtaScan type provides variants of parallel prefix scan across threads within a CTA.
 */

#pragma once

#include "../device_props.cuh"
#include "../type_utils.cuh"
#include "../operators.cuh"
#include "../warp/warp_scan.cuh"
#include "../thread/thread_reduce.cuh"
#include "../thread/thread_scan.cuh"
#include "../ns_wrapper.cuh"

CUB_NS_PREFIX

/// CUB namespace
namespace cub {

/// Tuning policy for cub::CtaScan
enum CtaScanPolicy
{
    CTA_SCAN_RAKING,        ///< Uses an work-efficient, but longer-latency algorithm (raking reduce-then-scan).  Useful when the GPU is fully occupied.
    CTA_SCAN_WARPSCANS,     ///< Uses an work-inefficient, but shorter-latency algorithm (tiled warpscans).  Useful when the GPU is under-occupied.
};

/**
 * \addtogroup SimtCoop
 * @{
 */

/**
 * \brief The CtaScan type provides variants of parallel prefix scan across threads within a CTA. ![](scan_logo.png)
 *
 * <b>Overview</b>
 * \par
 * Given a list of input elements and a binary reduction operator, <em>prefix scan</em>
 * produces an output list where each element is computed to be the reduction
 * of the elements occurring earlier in the input list.  <em>Prefix sum</em>
 * connotes a prefix scan with the addition operator. The term \em inclusive means
 * that each result includes the corresponding input operand in the partial sum.
 * The term \em exclusive means that each result does not include the corresponding
 * input operand in the partial reduction.
 *
 * \par
 * The parallel operations exposed by this type assume a <em>blocked</em>
 * arrangement of elements across threads, i.e., <em>n</em>-element
 * lists that are partitioned evenly across \p CTA_THREADS threads,
 * with thread<sub><em>i</em></sub> owning the <em>i</em><sup>th</sup>
 * element (or <em>i</em><sup>th</sup> segment of consecutive elements).
 *
 * \tparam T                The reduction input/output element type
 * \tparam CTA_THREADS      The CTA size in threads
 * \tparam POLICY           <b>[optional]</b> cub::CtaScanPolicy tuning policy enumeration.  Default = cub::CTA_SCAN_RAKING.
 *
 * <b>Important Features and Considerations</b>
 * \par
 * - Supports non-commutative scan operators.
 * - Very efficient (only two synchronization barriers).
 * - Zero bank conflicts for most types.
 * - After any operation, a subsequent CTA barrier (<tt>__syncthreads()</tt>) is
 *   required if the supplied CtaScan::SmemStorage is to be reused/repurposed by the CTA.
 * - The operations are most efficient (lowest instruction overhead) when:
 *      - The prefix-sum variants are used when addition is the reduction operator
 *      - The data type \p T is a built-in primitive or CUDA vector type (e.g.,
 *        \p short, \p int2, \p double, \p float2, etc.)  Otherwise the implementation may use memory
 *        fences to prevent reference reordering of non-primitive types.
 *      - \p CTA_THREADS is a multiple of the architecture's warp size
 * - To minimize synchronization overhead for operations involving the cumulative
 *   \p aggregate and \p cta_prefix_op, these values are only valid in <em>thread</em><sub>0</sub>.
 *
 * <b>Algorithm</b>
 * \par
 * The CtaScan type can be configured to use one of two alternative algorithms:
 *
 * \par
 *   -# <b>cub::CTA_SCAN_RAKING</b>.  Uses an work-efficient, but longer-latency algorithm (raking reduce-then-scan).  Useful when the GPU is fully occupied. These variants have <em>O</em>(<em>n</em>) work complexity and are comprised of five phases:
 *   <br><br>
 *     -# Upsweep sequential reduction in registers (if threads contribute more than one input each).  Each thread then places the partial reduction of its item(s) into shared memory.
 *     -# Upsweep sequential reduction in shared memory.  Threads within a single warp rake across segments of shared partial reductions.
 *     -# A warp-synchronous Kogge-Stone style exclusive scan within the raking warp.
 *     -# Downsweep sequential exclusive scan in shared memory.  Threads within a single warp rake across segments of shared partial reductions, seeded with the warp-scan output.
 *     -# Downsweep sequential scan in registers (if threads contribute more than one input), seeded with the raking scan output.
 *     <br><br>
 *     \image html cta_scan.png
 *     <center><b>\p CTA_SCAN_RAKING data flow for a hypothetical 16-thread CTA and 4-thread raking warp.</b></center>
 *     <br>
 *   -# <b>Algorithm cub::CTA_SCAN_WARPSCANS</b>.  Uses an work-inefficient, but shorter-latency algorithm (tiled warpscans).  Useful when the GPU is under-occupied.  These variants have <em>O</em>(<em>n</em>log<em>n</em>) work complexity and are comprised of XXX phases:
 *     -# Todo
 *     <br>
 *
 * <b>Examples</b>
 * \par
 * - <b>Example 1:</b> Simple exclusive prefix sum of 32-bit integer keys (128 threads, 4 keys per thread, blocked arrangement)
 *      \code
 *      #include <cub.cuh>
 *
 *      __global__ void SomeKernel(...)
 *      {
 *          // Parameterize a CtaScan type for use in the current problem context
 *          typedef cub::CtaScan<int, 128> CtaScan;
 *
 *          // Declare shared memory for CtaScan
 *          __shared__ typename CtaScan::SmemStorage smem_storage;
 *
 *          // A segment of consecutive input items per thread
 *          int data[4];
 *
 *          // Obtain items in blocked order
 *          ...
 *
 *          // Compute the CTA-wide exclusve prefix sum
 *          CtaScan::ExclusiveSum(smem_storage, data, data);

 *      \endcode
 *
 * \par
 * - <b>Example 2:</b> Use of local prefix sum and global atomic-add for performing cooperative allocation within a global data structure
 *      \code
 *      #include <cub.cuh>
 *
 *      /// Simple functor for producing a value for which to seed the entire local scan.
 *      struct CtaPrefixOp
 *      {
 *          int *d_global_counter;
 *
 *          /// Functor constructor
 *          CtaPrefix(int *d_global_counter) : d_global_counter(d_global_counter) {}
 *
 *          /// Functor operator.  Produces a value for seeding the CTA-wide scan given
 *          /// the local aggregate (called only by thread-0).
 *          int operator(int local_local_aggregate)
 *          {
 *              return atomicAdd(d_global_counter, local_local_aggregate);
 *          }
 *      }
 *
 *      template <int CTA_THREADS, int ITEMS_PER_THREAD>
 *      __global__ void SomeKernel(int *d_global_counter, ...)
 *      {
 *          // Parameterize a CtaScan type for use in the current problem context
 *          typedef cub::CtaScan<int, CTA_THREADS> CtaScan;
 *
 *          // Declare shared memory for CtaScan
 *          __shared__ typename CtaScan::SmemStorage smem_storage;
 *
 *          // A segment of consecutive input items per thread
 *          int data[ITEMS_PER_THREAD];

 *          // Obtain keys in blocked order
 *          ...
 *
 *          // Compute the CTA-wide exclusive prefix sum, seeded with a CTA-wide prefix
 *          int aggregate;
 *          CtaScan::ExclusiveSum(smem_storage, data, data, local_aggregate, CtaPrefix(d_global_counter));
 *      \endcode
 */
template <
    typename        T,
    int             CTA_THREADS,
    CtaScanPolicy   POLICY = CTA_SCAN_RAKING>
class CtaScan
{
private:

    //---------------------------------------------------------------------
    // Type definitions and constants
    //---------------------------------------------------------------------

    /// Layout type for padded CTA raking grid
    typedef CtaRakingGrid<CTA_THREADS, T> CtaRakingGrid;

    /// Constants
    enum
    {
        /// Number of active warps
        WARPS = (CTA_THREADS + DeviceProps::WARP_THREADS - 1) / DeviceProps::WARP_THREADS,

        /// Number of raking threads
        RAKING_THREADS = CtaRakingGrid::RAKING_THREADS,

        /// Number of raking elements per warp synchronous raking thread
        RAKING_LENGTH = CtaRakingGrid::RAKING_LENGTH,

        /// Cooperative work can be entirely warp synchronous
        WARP_SYNCHRONOUS = (CTA_THREADS == RAKING_THREADS),
    };

    ///  Raking warp-scan utility type
    typedef WarpScan<T, 1, RAKING_THREADS> WarpScan;

    /// Shared memory storage layout type
    struct SmemStorage
    {
        typename WarpScan::SmemStorage          warp_scan;      ///< Buffer for warp-synchronous scan
        typename CtaRakingGrid::SmemStorage     raking_grid;    ///< Padded CTA raking grid
    };

public:

    /// The operations exposed by CtaScan require shared memory of this
    /// type.  This opaque storage can be allocated directly using the
    /// <tt>__shared__</tt> keyword.  Alternatively, it can be aliased to
    /// externally allocated shared memory or <tt>union</tt>'d with other types
    /// to facilitate shared memory reuse.
    typedef SmemStorage SmemStorage;


    /******************************************************************//**
     * \name Exclusive prefix scans
     *********************************************************************/
    //@{


    /**
     * \brief Computes an exclusive CTA-wide prefix scan using the specified binary scan functor.  Each thread contributes one input element.  The inclusive CTA-wide \p aggregate of all inputs is computed for <em>thread</em><sub>0</sub>.
     *
     * The \p aggregate is undefined in threads other than <em>thread</em><sub>0</sub>.
     *
     * \smemreuse
     *
     * \tparam ScanOp   <b>[inferred]</b> Binary scan functor type
     */
    template <typename ScanOp>
    static __device__ __forceinline__ void ExclusiveScan(
        SmemStorage     &smem_storage,      ///< [in] Shared reference to opaque SmemStorage layout
        T               input,              ///< [in] Calling thread's input items
        T               &output,            ///< [out] Calling thread's output items (may be aliased to \p input)
        T               identity,           ///< [in] Identity value
        ScanOp          scan_op,            ///< [in] Binary scan operator
        T               &local_aggregate)   ///< [out] <b>[<em>thread</em><sub>0</sub> only]</b> CTA-wide aggregate reduction of input items
    {
        if (WARP_SYNCHRONOUS)
        {
            // Short-circuit directly to warp scan
            WarpScan::ExclusiveScan(
                smem_storage.warp_scan,
                input,
                output,
                identity,
                scan_op,
                local_aggregate);
        }
        else
        {
            // Place thread partial into shared memory raking grid
            T *placement_ptr = CtaRakingGrid::PlacementPtr(smem_storage.raking_grid);
            *placement_ptr = input;

            __syncthreads();

            // Reduce parallelism down to just raking threads
            if (threadIdx.x < RAKING_THREADS)
            {
                // Raking upsweep reduction in grid
                T *raking_ptr = CtaRakingGrid::RakingPtr(smem_storage.raking_grid);
                T raking_partial = ThreadReduce<RAKING_LENGTH>(raking_ptr, scan_op);

                // Exclusive warp synchronous scan
                WarpScan::ExclusiveScan(
                    smem_storage.warp_scan,
                    raking_partial,
                    raking_partial,
                    identity,
                    scan_op,
                    local_aggregate);

                // Exclusive raking downsweep scan
                ThreadScanExclusive<RAKING_LENGTH>(raking_ptr, raking_ptr, scan_op, raking_partial);

                if (!CtaRakingGrid::UNGUARDED)
                {
                    // CTA size isn't a multiple of warp size, so grab aggregate from the appropriate raking cell
                    local_aggregate = *CtaRakingGrid::PlacementPtr(smem_storage.raking_grid, 0, CTA_THREADS);
                }
            }

            __syncthreads();

            // Grab thread prefix from shared memory
            output = *placement_ptr;

        }
    }


    /**
     * \brief Computes an exclusive CTA-wide prefix scan using the specified binary scan functor.  Each thread contributes an array of consecutive input elements.  The inclusive CTA-wide \p aggregate of all inputs is computed for <em>thread</em><sub>0</sub>.
     *
     * The \p aggregate is undefined in threads other than <em>thread</em><sub>0</sub>.
     *
     * \smemreuse
     *
     * \tparam ITEMS_PER_THREAD     <b>[inferred]</b> The number of consecutive items partitioned onto each thread.
     * \tparam ScanOp               <b>[inferred]</b> Binary scan functor type
     */
    template <
        int             ITEMS_PER_THREAD,
        typename        ScanOp>
    static __device__ __forceinline__ void ExclusiveScan(
        SmemStorage       &smem_storage,                ///< [in] Shared reference to opaque SmemStorage layout
        T                 (&input)[ITEMS_PER_THREAD],   ///< [in] Calling thread's input items
        T                 (&output)[ITEMS_PER_THREAD],  ///< [out] Calling thread's output items (may be aliased to \p input)
        T                 identity,                     ///< [in] Identity value
        ScanOp            scan_op,                      ///< [in] Binary scan operator
        T                 &local_aggregate)             ///< [out] <b>[<em>thread</em><sub>0</sub> only]</b> CTA-wide aggregate reduction of input items
    {
        // Reduce consecutive thread items in registers
        T thread_partial = ThreadReduce(input, scan_op);

        // Exclusive CTA-scan
        ExclusiveScan(smem_storage, thread_partial, thread_partial, identity, scan_op, local_aggregate);

        // Exclusive scan in registers with prefix
        ThreadScanExclusive(input, output, scan_op, thread_partial);
    }


    /**
     * \brief Computes an exclusive CTA-wide prefix scan using the specified binary scan functor.  Each thread contributes one input element.  The functor \p cta_prefix_op is evaluated by <em>thread</em><sub>0</sub> to provide the preceding (or "base") value that logically prefixes the CTA's scan inputs.  The inclusive CTA-wide \p aggregate of all inputs is computed for <em>thread</em><sub>0</sub>.
     *
     * The \p aggregate and \p cta_prefix_op are undefined in threads other than <em>thread</em><sub>0</sub>.
     *
     * \smemreuse
     *
     * \tparam ScanOp               <b>[inferred]</b> Binary scan functor type
     * \tparam CtaPrefixOp          <b>[inferred]</b> A call-back unary functor of the model </em>operator()(T local_local_aggregate)</em>
     */
    template <
        typename ScanOp,
        typename CtaPrefixOp>
    static __device__ __forceinline__ void ExclusiveScan(
        SmemStorage     &smem_storage,                  ///< [in] Shared reference to opaque SmemStorage layout
        T               input,                          ///< [in] Calling thread's input item
        T               &output,                        ///< [out] Calling thread's output item (may be aliased to \p input)
        T               identity,                       ///< [in] Identity value
        ScanOp          scan_op,                        ///< [in] Binary scan operator
        T               &local_aggregate,               ///< [out] <b>[<em>thread</em><sub>0</sub> only]</b> CTA-wide aggregate reduction of input items, exclusive of the \p cta_prefix_op value
        CtaPrefixOp     &cta_prefix_op)                 ///< [in-out] <b>[<em>thread</em><sub>0</sub> only]</b> A call-back unary functor of the model </em>operator()(T local_local_aggregate)</em> to be run <em>thread</em><sub>0</sub>.  When provided the CTA-wide aggregate of input items, this functor is expected to return the logical CTA-wide prefix to be applied during the scan operation.  Can be stateful.
    {
        if (WARP_SYNCHRONOUS)
        {
            // Short-circuit directly to warp scan
            WarpScan::ExclusiveScan(
                smem_storage.warp_scan,
                input,
                output,
                identity,
                scan_op,
                local_aggregate,
                cta_prefix_op);
        }
        else
        {
            // Place thread partial into shared memory raking grid
            T *placement_ptr = CtaRakingGrid::PlacementPtr(smem_storage.raking_grid);
            *placement_ptr = input;

            __syncthreads();

            // Reduce parallelism down to just raking threads
            if (threadIdx.x < RAKING_THREADS)
            {
                // Raking upsweep reduction in grid
                T *raking_ptr = CtaRakingGrid::RakingPtr(smem_storage.raking_grid);
                T raking_partial = ThreadReduce<RAKING_LENGTH>(raking_ptr, scan_op);

                // Exclusive warp synchronous scan
                WarpScan::ExclusiveScan(
                    smem_storage.warp_scan,
                    raking_partial,
                    raking_partial,
                    identity,
                    scan_op,
                    local_aggregate,
                    cta_prefix_op);

                // Exclusive raking downsweep scan
                ThreadScanExclusive<RAKING_LENGTH>(raking_ptr, raking_ptr, scan_op, raking_partial);

                if (!CtaRakingGrid::UNGUARDED)
                {
                    // CTA size isn't a multiple of warp size, so grab aggregate from the appropriate raking cell
                    local_aggregate = *CtaRakingGrid::PlacementPtr(smem_storage.raking_grid, 0, CTA_THREADS);
                }
            }

            __syncthreads();

            // Grab thread prefix from shared memory
            output = *placement_ptr;
        }
    }


    /**
     * \brief Computes an exclusive CTA-wide prefix scan using the specified binary scan functor.  Each thread contributes an array of consecutive input elements.  The functor \p cta_prefix_op is evaluated by <em>thread</em><sub>0</sub> to provide the preceding (or "base") value that logically prefixes the CTA's scan inputs.  The inclusive CTA-wide \p aggregate of all inputs is computed for <em>thread</em><sub>0</sub>.
     *
     * The \p aggregate and \p cta_prefix_op are undefined in threads other than <em>thread</em><sub>0</sub>.
     *
     * \smemreuse
     *
     * \tparam ITEMS_PER_THREAD     <b>[inferred]</b> The number of consecutive items partitioned onto each thread.
     * \tparam ScanOp               <b>[inferred]</b> Binary scan functor type
     * \tparam CtaPrefixOp          <b>[inferred]</b> A call-back unary functor of the model </em>operator()(T local_local_aggregate)</em>
     */
    template <
        int             ITEMS_PER_THREAD,
        typename        ScanOp,
        typename        CtaPrefixOp>
    static __device__ __forceinline__ void ExclusiveScan(
        SmemStorage     &smem_storage,                  ///< [in] Shared reference to opaque SmemStorage layout
        T               (&input)[ITEMS_PER_THREAD],     ///< [in] Calling thread's input items
        T               (&output)[ITEMS_PER_THREAD],    ///< [out] Calling thread's output items (may be aliased to \p input)
        T               identity,                       ///< [in] Identity value
        ScanOp          scan_op,                        ///< [in] Binary scan operator
        T               &local_aggregate,               ///< [out] <b>[<em>thread</em><sub>0</sub> only]</b> CTA-wide aggregate reduction of input items, exclusive of the \p cta_prefix_op value
        CtaPrefixOp     &cta_prefix_op)                 ///< [in-out] <b>[<em>thread</em><sub>0</sub> only]</b> A call-back unary functor of the model </em>operator()(T local_local_aggregate)</em> to be run <em>thread</em><sub>0</sub>.  When provided the CTA-wide aggregate of input items, this functor is expected to return the logical CTA-wide prefix to be applied during the scan operation.  Can be stateful.
    {
        // Reduce consecutive thread items in registers
        T thread_partial = ThreadReduce(input, scan_op);

        // Exclusive CTA-scan
        ExclusiveScan(smem_storage, thread_partial, thread_partial, identity, scan_op, local_aggregate, cta_prefix_op);

        // Exclusive scan in registers with prefix
        ThreadScanExclusive(input, output, scan_op, thread_partial);
    }


    /**
     * \brief Computes an exclusive CTA-wide prefix scan using the specified binary scan functor.  Each thread contributes one input element.
     *
     * \smemreuse
     *
     * \tparam ScanOp               <b>[inferred]</b> Binary scan functor type
     */
    template <typename ScanOp>
    static __device__ __forceinline__ void ExclusiveScan(
        SmemStorage     &smem_storage,                  ///< [in] Shared reference to opaque SmemStorage layout
        T               input,                          ///< [in] Calling thread's input item
        T               &output,                        ///< [out] Calling thread's output item (may be aliased to \p input)
        T               identity,                       ///< [in] Identity value
        ScanOp          scan_op)                        ///< [in] Binary scan operator
    {
        T local_aggregate;
        ExclusiveScan(smem_storage, input, output, identity, scan_op, local_aggregate);
    }



    /**
     * \brief Computes an exclusive CTA-wide prefix scan using the specified binary scan functor.  Each thread contributes an array of consecutive input elements.
     *
     * \smemreuse
     *
     * \tparam ITEMS_PER_THREAD     <b>[inferred]</b> The number of consecutive items partitioned onto each thread.
     * \tparam ScanOp               <b>[inferred]</b> Binary scan functor type
     */
    template <
        int             ITEMS_PER_THREAD,
        typename         ScanOp>
    static __device__ __forceinline__ void ExclusiveScan(
        SmemStorage       &smem_storage,                ///< [in] Shared reference to opaque SmemStorage layout
        T                 (&input)[ITEMS_PER_THREAD],   ///< [in] Calling thread's input items
        T                 (&output)[ITEMS_PER_THREAD],  ///< [out] Calling thread's output items (may be aliased to \p input)
        T                 identity,                     ///< [in] Identity value
        ScanOp            scan_op)                      ///< [in] Binary scan operator
    {
        // Reduce consecutive thread items in registers
        T thread_partial = ThreadReduce(input, scan_op);

        // Exclusive CTA-scan
        ExclusiveScan(smem_storage, thread_partial, thread_partial, identity, scan_op);

        // Exclusive scan in registers with prefix
        ThreadScanExclusive(input, output, scan_op, thread_partial);
    }


    //@}
    /******************************************************************//**
     * \name Exclusive prefix scans (without supplied identity)
     *********************************************************************/
    //@{


    /**
     * \brief Computes an exclusive CTA-wide prefix scan using the specified binary scan functor.  Each thread contributes one input element.  The inclusive CTA-wide \p aggregate of all inputs is computed for <em>thread</em><sub>0</sub>.  With no identity value, the output computed for <em>thread</em><sub>0</sub> is invalid.
     *
     * The \p aggregate is undefined in threads other than <em>thread</em><sub>0</sub>.
     *
     * \smemreuse
     *
     * \tparam ScanOp   <b>[inferred]</b> Binary scan functor type
     */
    template <typename ScanOp>
    static __device__ __forceinline__ void ExclusiveScan(
        SmemStorage     &smem_storage,                  ///< [in] Shared reference to opaque SmemStorage layout
        T               input,                          ///< [in] Calling thread's input item
        T               &output,                        ///< [out] Calling thread's output item (may be aliased to \p input)
        ScanOp          scan_op,                        ///< [in] Binary scan operator
        T               &local_aggregate)               ///< [out] <b>[<em>thread</em><sub>0</sub> only]</b> CTA-wide aggregate reduction of input items
    {
        if (WARP_SYNCHRONOUS)
        {
            // Short-circuit directly to warp scan
            WarpScan::ExclusiveScan(
                smem_storage.warp_scan,
                input,
                output,
                scan_op,
                local_aggregate);
        }
        else
        {
            // Place thread partial into shared memory raking grid
            T *placement_ptr = CtaRakingGrid::PlacementPtr(smem_storage.raking_grid);
            *placement_ptr = input;

            __syncthreads();

            // Reduce parallelism down to just raking threads
            if (threadIdx.x < RAKING_THREADS)
            {
                // Raking upsweep reduction in grid
                T *raking_ptr = CtaRakingGrid::RakingPtr(smem_storage.raking_grid);
                T raking_partial = ThreadReduce<RAKING_LENGTH>(raking_ptr, scan_op);

                // Exclusive warp synchronous scan
                WarpScan::ExclusiveScan(
                    smem_storage.warp_scan,
                    raking_partial,
                    raking_partial,
                    scan_op,
                    local_aggregate);

                // Exclusive raking downsweep scan
                ThreadScanExclusive<RAKING_LENGTH>(raking_ptr, raking_ptr, scan_op, raking_partial, (threadIdx.x != 0));

                if (!CtaRakingGrid::UNGUARDED)
                {
                    // CTA size isn't a multiple of warp size, so grab aggregate from the appropriate raking cell
                    local_aggregate = *CtaRakingGrid::PlacementPtr(smem_storage.raking_grid, 0, CTA_THREADS);
                }
            }

            __syncthreads();

            // Grab thread prefix from shared memory
            output = *placement_ptr;
        }
    }


    /**
     * \brief Computes an exclusive CTA-wide prefix scan using the specified binary scan functor.  Each thread contributes an array of consecutive input elements.  The inclusive CTA-wide \p aggregate of all inputs is computed for <em>thread</em><sub>0</sub>.  With no identity value, the output computed for <em>thread</em><sub>0</sub> is invalid.
     *
     * The \p aggregate is undefined in threads other than <em>thread</em><sub>0</sub>.
     *
     * \smemreuse
     *
     * \tparam ITEMS_PER_THREAD     <b>[inferred]</b> The number of consecutive items partitioned onto each thread.
     * \tparam ScanOp               <b>[inferred]</b> Binary scan functor type
     */
    template <
        int             ITEMS_PER_THREAD,
        typename         ScanOp>
    static __device__ __forceinline__ void ExclusiveScan(
        SmemStorage        &smem_storage,               ///< [in] Shared reference to opaque SmemStorage layout
        T                 (&input)[ITEMS_PER_THREAD],   ///< [in] Calling thread's input items
        T                 (&output)[ITEMS_PER_THREAD],  ///< [out] Calling thread's output items (may be aliased to \p input)
        ScanOp          scan_op,                        ///< [in] Binary scan operator
        T               &local_aggregate)               ///< [out] <b>[<em>thread</em><sub>0</sub> only]</b> CTA-wide aggregate reduction of input items
    {
        // Reduce consecutive thread items in registers
        T thread_partial = ThreadReduce(input, scan_op);

        // Exclusive CTA-scan
        ExclusiveScan(smem_storage, thread_partial, thread_partial, scan_op, local_aggregate);

        // Exclusive scan in registers with prefix
        ThreadScanExclusive(input, output, scan_op, thread_partial, (threadIdx.x != 0));
    }


    /**
     * \brief Computes an exclusive CTA-wide prefix scan using the specified binary scan functor.  Each thread contributes one input element.  The functor \p cta_prefix_op is evaluated by <em>thread</em><sub>0</sub> to provide the preceding (or "base") value that logically prefixes the CTA's scan inputs.  The inclusive CTA-wide \p aggregate of all inputs is computed for <em>thread</em><sub>0</sub>.  With no identity value, the output computed for <em>thread</em><sub>0</sub> is invalid.
     *
     * The \p aggregate and \p cta_prefix_op are undefined in threads other than <em>thread</em><sub>0</sub>.
     *
     * \smemreuse
     *
     * \tparam ScanOp               <b>[inferred]</b> Binary scan functor type
     * \tparam CtaPrefixOp          <b>[inferred]</b> A call-back unary functor of the model </em>operator()(T local_local_aggregate)</em>
     */
    template <
        typename ScanOp,
        typename CtaPrefixOp>
    static __device__ __forceinline__ void ExclusiveScan(
        SmemStorage     &smem_storage,                  ///< [in] Shared reference to opaque SmemStorage layout
        T               input,                          ///< [in] Calling thread's input item
        T               &output,                        ///< [out] Calling thread's output item (may be aliased to \p input)
        ScanOp          scan_op,                        ///< [in] Binary scan operator
        T               &local_aggregate,               ///< [out] <b>[<em>thread</em><sub>0</sub> only]</b> CTA-wide aggregate reduction of input items, exclusive of the \p cta_prefix_op value
        CtaPrefixOp     &cta_prefix_op)                 ///< [in-out] <b>[<em>thread</em><sub>0</sub> only]</b> A call-back unary functor of the model </em>operator()(T local_local_aggregate)</em> to be run <em>thread</em><sub>0</sub>.  When provided the CTA-wide aggregate of input items, this functor is expected to return the logical CTA-wide prefix to be applied during the scan operation.  Can be stateful.
    {
        if (WARP_SYNCHRONOUS)
        {
            // Short-circuit directly to warp scan
            WarpScan::ExclusiveScan(
                smem_storage.warp_scan,
                input,
                output,
                scan_op,
                local_aggregate,
                cta_prefix_op);
        }
        else
        {
            // Place thread partial into shared memory raking grid
            T *placement_ptr = CtaRakingGrid::PlacementPtr(smem_storage.raking_grid);
            *placement_ptr = input;

            __syncthreads();

            // Reduce parallelism down to just raking threads
            if (threadIdx.x < RAKING_THREADS)
            {
                // Raking upsweep reduction in grid
                T *raking_ptr = CtaRakingGrid::RakingPtr(smem_storage.raking_grid);
                T raking_partial = ThreadReduce<RAKING_LENGTH>(raking_ptr, scan_op);

                // Exclusive warp synchronous scan
                WarpScan::ExclusiveScan(
                    smem_storage.warp_scan,
                    raking_partial,
                    raking_partial,
                    scan_op,
                    local_aggregate,
                    cta_prefix_op);

                // Exclusive raking downsweep scan
                ThreadScanExclusive<RAKING_LENGTH>(raking_ptr, raking_ptr, scan_op, raking_partial);

                if (!CtaRakingGrid::UNGUARDED)
                {
                    // CTA size isn't a multiple of warp size, so grab aggregate from the appropriate raking cell
                    local_aggregate = *CtaRakingGrid::PlacementPtr(smem_storage.raking_grid, 0, CTA_THREADS);
                }
            }

            __syncthreads();

            // Grab thread prefix from shared memory
            output = *placement_ptr;
        }
    }


    /**
     * \brief Computes an exclusive CTA-wide prefix scan using the specified binary scan functor.  Each thread contributes an array of consecutive input elements.  The functor \p cta_prefix_op is evaluated by <em>thread</em><sub>0</sub> to provide the preceding (or "base") value that logically prefixes the CTA's scan inputs.  The inclusive CTA-wide \p aggregate of all inputs is computed for <em>thread</em><sub>0</sub>.  With no identity value, the output computed for <em>thread</em><sub>0</sub> is invalid.
     *
     * The \p aggregate and \p cta_prefix_op are undefined in threads other than <em>thread</em><sub>0</sub>.
     *
     * \smemreuse
     *
     * \tparam ITEMS_PER_THREAD     <b>[inferred]</b> The number of consecutive items partitioned onto each thread.
     * \tparam ScanOp               <b>[inferred]</b> Binary scan functor type
     * \tparam CtaPrefixOp          <b>[inferred]</b> A call-back unary functor of the model </em>operator()(T local_local_aggregate)</em>
     */
    template <
        int             ITEMS_PER_THREAD,
        typename        ScanOp,
        typename        CtaPrefixOp>
    static __device__ __forceinline__ void ExclusiveScan(
        SmemStorage      &smem_storage,               ///< [in] Shared reference to opaque SmemStorage layout
        T               (&input)[ITEMS_PER_THREAD],   ///< [in] Calling thread's input items
        T               (&output)[ITEMS_PER_THREAD],  ///< [out] Calling thread's output items (may be aliased to \p input)
        ScanOp          scan_op,                      ///< [in] Binary scan operator
        T               &local_aggregate,             ///< [out] <b>[<em>thread</em><sub>0</sub> only]</b> CTA-wide aggregate reduction of input items, exclusive of the \p cta_prefix_op value
        CtaPrefixOp     &cta_prefix_op)               ///< [in-out] <b>[<em>thread</em><sub>0</sub> only]</b> A call-back unary functor of the model </em>operator()(T local_local_aggregate)</em> to be run <em>thread</em><sub>0</sub>.  When provided the CTA-wide aggregate of input items, this functor is expected to return the logical CTA-wide prefix to be applied during the scan operation.  Can be stateful.
    {
        // Reduce consecutive thread items in registers
        T thread_partial = ThreadReduce(input, scan_op);

        // Exclusive CTA-scan
        ExclusiveScan(smem_storage, thread_partial, thread_partial, scan_op, local_aggregate, cta_prefix_op);

        // Exclusive scan in registers with prefix
        ThreadScanExclusive(input, output, scan_op, thread_partial);
    }


    /**
     * \brief Computes an exclusive CTA-wide prefix scan using the specified binary scan functor.  Each thread contributes one input element.  With no identity value, the output computed for <em>thread</em><sub>0</sub> is invalid.
     *
     * \smemreuse
     *
     * \tparam ScanOp               <b>[inferred]</b> Binary scan functor type
     */
    template <typename ScanOp>
    static __device__ __forceinline__ void ExclusiveScan(
        SmemStorage     &smem_storage,                  ///< [in] Shared reference to opaque SmemStorage layout
        T               input,                          ///< [in] Calling thread's input item
        T               &output,                        ///< [out] Calling thread's output item (may be aliased to \p input)
        ScanOp          scan_op)                        ///< [in] Binary scan operator
    {
        T local_aggregate;
        ExclusiveScan(smem_storage, input, output, scan_op, local_aggregate);
    }


    /**
     * \brief Computes an exclusive CTA-wide prefix scan using the specified binary scan functor.  Each thread contributes an array of consecutive input elements.  With no identity value, the output computed for <em>thread</em><sub>0</sub> is invalid.
     *
     * \smemreuse
     *
     * \tparam ITEMS_PER_THREAD     <b>[inferred]</b> The number of consecutive items partitioned onto each thread.
     * \tparam ScanOp               <b>[inferred]</b> Binary scan functor type
     */
    template <
        int             ITEMS_PER_THREAD,
        typename         ScanOp>
    static __device__ __forceinline__ void ExclusiveScan(
        SmemStorage        &smem_storage,               ///< [in] Shared reference to opaque SmemStorage layout
        T                 (&input)[ITEMS_PER_THREAD],   ///< [in] Calling thread's input items
        T                 (&output)[ITEMS_PER_THREAD],  ///< [out] Calling thread's output items (may be aliased to \p input)
        ScanOp            scan_op)                      ///< [in] Binary scan operator
    {
        // Reduce consecutive thread items in registers
        T thread_partial = ThreadReduce(input, scan_op);

        // Exclusive CTA-scan
        ExclusiveScan(smem_storage, thread_partial, thread_partial, scan_op);

        // Exclusive scan in registers with prefix
        ThreadScanExclusive(input, output, scan_op, thread_partial, (threadIdx.x != 0));
    }


    //@}
    /******************************************************************//**
     * \name Exclusive prefix sums
     *********************************************************************/
    //@{


    /**
     * \brief Computes an exclusive CTA-wide prefix scan using addition (+) as the scan operator.  Each thread contributes one input element.  The inclusive CTA-wide \p aggregate of all inputs is computed for <em>thread</em><sub>0</sub>.
     *
     * The \p aggregate is undefined in threads other than <em>thread</em><sub>0</sub>.
     *
     * \smemreuse
     */
    static __device__ __forceinline__ void ExclusiveSum(
        SmemStorage     &smem_storage,                  ///< [in] Shared reference to opaque SmemStorage layout
        T               input,                          ///< [in] Calling thread's input item
        T               &output,                        ///< [out] Calling thread's output item (may be aliased to \p input)
        T               &local_aggregate)               ///< [out] <b>[<em>thread</em><sub>0</sub> only]</b> CTA-wide aggregate reduction of input items
    {
        if (WARP_SYNCHRONOUS)
        {
            // Short-circuit directly to warp scan
            WarpScan::ExclusiveSum(
                smem_storage.warp_scan,
                input,
                output,
                local_aggregate);
        }
        else
        {
            // Raking scan
            Sum<T> scan_op;

            // Place thread partial into shared memory raking grid
            T *placement_ptr = CtaRakingGrid::PlacementPtr(smem_storage.raking_grid);
            *placement_ptr = input;

            __syncthreads();

            // Reduce parallelism down to just raking threads
            if (threadIdx.x < RAKING_THREADS)
            {
                // Raking upsweep reduction in grid
                T *raking_ptr = CtaRakingGrid::RakingPtr(smem_storage.raking_grid);
                T raking_partial = ThreadReduce<RAKING_LENGTH>(raking_ptr, scan_op);

                // Exclusive warp synchronous scan
                WarpScan::ExclusiveSum(
                    smem_storage.warp_scan,
                    raking_partial,
                    raking_partial,
                    local_aggregate);

                // Exclusive raking downsweep scan
                ThreadScanExclusive<RAKING_LENGTH>(raking_ptr, raking_ptr, scan_op, raking_partial, (threadIdx.x != 0));

                if (!CtaRakingGrid::UNGUARDED)
                {
                    // CTA size isn't a multiple of warp size, so grab aggregate from the appropriate raking cell
                    local_aggregate = *CtaRakingGrid::PlacementPtr(smem_storage.raking_grid, 0, CTA_THREADS);
                }
            }

            __syncthreads();

            // Grab thread prefix from shared memory
            output = *placement_ptr;
        }
    }


    /**
     * \brief Computes an exclusive CTA-wide prefix scan using addition (+) as the scan operator.  Each thread contributes an array of consecutive input elements.  The inclusive CTA-wide \p aggregate of all inputs is computed for <em>thread</em><sub>0</sub>.
     *
     * The \p aggregate is undefined in threads other than <em>thread</em><sub>0</sub>.
     *
     * \smemreuse
     *
     * \tparam ITEMS_PER_THREAD     <b>[inferred]</b> The number of consecutive items partitioned onto each thread.
     */
    template <int ITEMS_PER_THREAD>
    static __device__ __forceinline__ void ExclusiveSum(
        SmemStorage        &smem_storage,                   ///< [in] Shared reference to opaque SmemStorage layout
        T                 (&input)[ITEMS_PER_THREAD],       ///< [in] Calling thread's input items
        T                 (&output)[ITEMS_PER_THREAD],      ///< [out] Calling thread's output items (may be aliased to \p input)
        T                 &local_aggregate)                 ///< [out] <b>[<em>thread</em><sub>0</sub> only]</b> CTA-wide aggregate reduction of input items
    {
        // Reduce consecutive thread items in registers
        Sum<T> scan_op;
        T thread_partial = ThreadReduce(input, scan_op);

        // Exclusive CTA-scan
        ExclusiveSum(smem_storage, thread_partial, thread_partial, local_aggregate);

        // Exclusive scan in registers with prefix
        ThreadScanExclusive(input, output, scan_op, thread_partial, (threadIdx.x != 0));
    }


    /**
     * \brief Computes an exclusive CTA-wide prefix scan using addition (+) as the scan operator.  Each thread contributes one input element.  The functor \p cta_prefix_op is evaluated by <em>thread</em><sub>0</sub> to provide the preceding (or "base") value that logically prefixes the CTA's scan inputs.  The inclusive CTA-wide \p aggregate of all inputs is computed for <em>thread</em><sub>0</sub>.
     *
     * The \p aggregate and \p cta_prefix_op are undefined in threads other than <em>thread</em><sub>0</sub>.
     *
     * \smemreuse
     *
     * \tparam CtaPrefixOp          <b>[inferred]</b> A call-back unary functor of the model </em>operator()(T local_local_aggregate)</em>
     */
    template <typename CtaPrefixOp>
    static __device__ __forceinline__ void ExclusiveSum(
        SmemStorage     &smem_storage,                  ///< [in] Shared reference to opaque SmemStorage layout
        T               input,                          ///< [in] Calling thread's input item
        T               &output,                        ///< [out] Calling thread's output item (may be aliased to \p input)
        T               &local_aggregate,               ///< [out] <b>[<em>thread</em><sub>0</sub> only]</b> CTA-wide aggregate reduction of input items, exclusive of the \p cta_prefix_op value
        CtaPrefixOp     &cta_prefix_op)                 ///< [in-out] <b>[<em>thread</em><sub>0</sub> only]</b> A call-back unary functor of the model </em>T cta_prefix_op(T local_aggregate)</em> to be run <em>thread</em><sub>0</sub> for providing the operation with a CTA-wide prefix value to seed the scan with.  Can be stateful.
    {
        if (WARP_SYNCHRONOUS)
        {
            // Short-circuit directly to warp scan
            WarpScan::ExclusiveSum(
                smem_storage.warp_scan,
                input,
                output,
                local_aggregate,
                cta_prefix_op);
        }
        else
        {
            // Raking scan
            Sum<T> scan_op;

            // Place thread partial into shared memory raking grid
            T *placement_ptr = CtaRakingGrid::PlacementPtr(smem_storage.raking_grid);
            *placement_ptr = input;

            __syncthreads();

            // Reduce parallelism down to just raking threads
            if (threadIdx.x < RAKING_THREADS)
            {
                // Raking upsweep reduction in grid
                T *raking_ptr = CtaRakingGrid::RakingPtr(smem_storage.raking_grid);
                T raking_partial = ThreadReduce<RAKING_LENGTH>(raking_ptr, scan_op);

                // Exclusive warp synchronous scan
                WarpScan::ExclusiveSum(
                    smem_storage.warp_scan,
                    raking_partial,
                    raking_partial,
                    local_aggregate,
                    cta_prefix_op);

                // Exclusive raking downsweep scan
                ThreadScanExclusive<RAKING_LENGTH>(raking_ptr, raking_ptr, scan_op, raking_partial);

                if (!CtaRakingGrid::UNGUARDED)
                {
                    // CTA size isn't a multiple of warp size, so grab aggregate from the appropriate raking cell
                    local_aggregate = *CtaRakingGrid::PlacementPtr(smem_storage.raking_grid, 0, CTA_THREADS);
                }
            }

            __syncthreads();

            // Grab thread prefix from shared memory
            output = *placement_ptr;
        }
    }


    /**
     * \brief Computes an exclusive CTA-wide prefix scan using addition (+) as the scan operator.  Each thread contributes an array of consecutive input elements.  The functor \p cta_prefix_op is evaluated by <em>thread</em><sub>0</sub> to provide the preceding (or "base") value that logically prefixes the CTA's scan inputs.  The inclusive CTA-wide \p aggregate of all inputs is computed for <em>thread</em><sub>0</sub>.
     *
     * The \p aggregate and \p cta_prefix_op are undefined in threads other than <em>thread</em><sub>0</sub>.
     *
     * \smemreuse
     *
     * \tparam ITEMS_PER_THREAD     <b>[inferred]</b> The number of consecutive items partitioned onto each thread.
     * \tparam CtaPrefixOp          <b>[inferred]</b> A call-back unary functor of the model </em>operator()(T local_local_aggregate)</em>
     */
    template <
        int ITEMS_PER_THREAD,
        typename CtaPrefixOp>
    static __device__ __forceinline__ void ExclusiveSum(
        SmemStorage       &smem_storage,                ///< [in] Shared reference to opaque SmemStorage layout
        T                 (&input)[ITEMS_PER_THREAD],   ///< [in] Calling thread's input items
        T                 (&output)[ITEMS_PER_THREAD],  ///< [out] Calling thread's output items (may be aliased to \p input)
        T                 &local_aggregate,             ///< [out] <b>[<em>thread</em><sub>0</sub> only]</b> CTA-wide aggregate reduction of input items, exclusive of the \p cta_prefix_op value
        CtaPrefixOp       &cta_prefix_op)               ///< [in-out] <b>[<em>thread</em><sub>0</sub> only]</b> A call-back unary functor of the model </em>operator()(T local_local_aggregate)</em> to be run <em>thread</em><sub>0</sub>.  When provided the CTA-wide aggregate of input items, this functor is expected to return the logical CTA-wide prefix to be applied during the scan operation.  Can be stateful.
    {
        // Reduce consecutive thread items in registers
        Sum<T> scan_op;
        T thread_partial = ThreadReduce(input, scan_op);

        // Exclusive CTA-scan
        ExclusiveSum(smem_storage, thread_partial, thread_partial, local_aggregate, cta_prefix_op);

        // Exclusive scan in registers with prefix
        ThreadScanExclusive(input, output, scan_op, thread_partial);
    }


    /**
     * \brief Computes an exclusive CTA-wide prefix scan using addition (+) as the scan operator.  Each thread contributes one input element.
     *
     * \smemreuse
     */
    static __device__ __forceinline__ void ExclusiveSum(
        SmemStorage     &smem_storage,                  ///< [in] Shared reference to opaque SmemStorage layout
        T               input,                          ///< [in] Calling thread's input item
        T               &output)                        ///< [out] Calling thread's output item (may be aliased to \p input)
    {
        T local_aggregate;
        ExclusiveSum(smem_storage, input, output, local_aggregate);
    }


    /**
     * \brief Computes an exclusive CTA-wide prefix scan using addition (+) as the scan operator.  Each thread contributes an array of consecutive input elements.
     *
     * \smemreuse
     *
     * \tparam ITEMS_PER_THREAD     <b>[inferred]</b> The number of consecutive items partitioned onto each thread.
     */
    template <int ITEMS_PER_THREAD>
    static __device__ __forceinline__ void ExclusiveSum(
        SmemStorage        &smem_storage,               ///< [in] Shared reference to opaque SmemStorage layout
        T                 (&input)[ITEMS_PER_THREAD],   ///< [in] Calling thread's input items
        T                 (&output)[ITEMS_PER_THREAD])  ///< [out] Calling thread's output items (may be aliased to \p input)
    {
        // Reduce consecutive thread items in registers
        Sum<T> scan_op;
        T thread_partial = ThreadReduce(input, scan_op);

        // Exclusive CTA-scan
        ExclusiveSum(smem_storage, thread_partial, thread_partial);

        // Exclusive scan in registers with prefix
        ThreadScanExclusive(input, output, scan_op, thread_partial, (threadIdx.x != 0));
    }


    //@}
    /******************************************************************//**
     * \name Inclusive prefix scans
     *********************************************************************/
    //@{


    /**
     * \brief Computes an inclusive CTA-wide prefix scan using the specified binary scan functor.  Each thread contributes one input element.  The inclusive CTA-wide \p aggregate of all inputs is computed for <em>thread</em><sub>0</sub>.
     *
     * The \p aggregate is undefined in threads other than <em>thread</em><sub>0</sub>.
     *
     * \smemreuse
     *
     * \tparam ScanOp   <b>[inferred]</b> Binary scan functor type
     */
    template <typename ScanOp>
    static __device__ __forceinline__ void InclusiveScan(
        SmemStorage     &smem_storage,                  ///< [in] Shared reference to opaque SmemStorage layout
        T               input,                          ///< [in] Calling thread's input item
        T               &output,                        ///< [out] Calling thread's output item (may be aliased to \p input)
        ScanOp          scan_op,                        ///< [in] Binary scan operator
        T               &local_aggregate)               ///< [out] <b>[<em>thread</em><sub>0</sub> only]</b> CTA-wide aggregate reduction of input items
    {
        if (WARP_SYNCHRONOUS)
        {
            // Short-circuit directly to warp scan
            WarpScan::InclusiveScan(
                smem_storage.warp_scan,
                input,
                output,
                scan_op,
                local_aggregate);
        }
        else
        {
            // Place thread partial into shared memory raking grid
            T *placement_ptr = CtaRakingGrid::PlacementPtr(smem_storage.raking_grid);
            *placement_ptr = input;

            __syncthreads();

            // Reduce parallelism down to just raking threads
            if (threadIdx.x < RAKING_THREADS)
            {
                // Raking upsweep reduction in grid
                T *raking_ptr = CtaRakingGrid::RakingPtr(smem_storage.raking_grid);
                T raking_partial = ThreadReduce<RAKING_LENGTH>(raking_ptr, scan_op);

                // Exclusive warp synchronous scan
                WarpScan::ExclusiveScan(
                    smem_storage.warp_scan,
                    raking_partial,
                    raking_partial,
                    scan_op,
                    local_aggregate);

                // Exclusive raking downsweep scan
                ThreadScanExclusive<RAKING_LENGTH>(raking_ptr, raking_ptr, scan_op, raking_partial, (threadIdx.x != 0));

                if (!CtaRakingGrid::UNGUARDED)
                {
                    // CTA size isn't a multiple of warp size, so grab aggregate from the appropriate raking cell
                    local_aggregate = *CtaRakingGrid::PlacementPtr(smem_storage.raking_grid, 0, CTA_THREADS);
                }
            }

            __syncthreads();

            // Grab thread prefix from shared memory
            output = *placement_ptr;
        }
    }


    /**
     * \brief Computes an inclusive CTA-wide prefix scan using the specified binary scan functor.  Each thread contributes an array of consecutive input elements.  The inclusive CTA-wide \p aggregate of all inputs is computed for <em>thread</em><sub>0</sub>.
     *
     * The \p aggregate is undefined in threads other than <em>thread</em><sub>0</sub>.
     *
     * \smemreuse
     *
     * \tparam ITEMS_PER_THREAD     <b>[inferred]</b> The number of consecutive items partitioned onto each thread.
     * \tparam ScanOp               <b>[inferred]</b> Binary scan functor type
     */
    template <
        int             ITEMS_PER_THREAD,
        typename         ScanOp>
    static __device__ __forceinline__ void InclusiveScan(
        SmemStorage     &smem_storage,                  ///< [in] Shared reference to opaque SmemStorage layout
        T               (&input)[ITEMS_PER_THREAD],     ///< [in] Calling thread's input items
        T               (&output)[ITEMS_PER_THREAD],    ///< [out] Calling thread's output items (may be aliased to \p input)
        ScanOp          scan_op,                        ///< [in] Binary scan operator
        T               &local_aggregate)               ///< [out] <b>[<em>thread</em><sub>0</sub> only]</b> CTA-wide aggregate reduction of input items
    {
        // Reduce consecutive thread items in registers
        T thread_partial = ThreadReduce(input, scan_op);

        // Exclusive CTA-scan
        ExclusiveScan(smem_storage, thread_partial, thread_partial, scan_op, local_aggregate);

        // Inclusive scan in registers with prefix
        ThreadScanInclusive(input, output, scan_op, thread_partial, (threadIdx.x != 0));
    }


    /**
     * \brief Computes an inclusive CTA-wide prefix scan using the specified binary scan functor.  Each thread contributes one input element.  The functor \p cta_prefix_op is evaluated by <em>thread</em><sub>0</sub> to provide the preceding (or "base") value that logically prefixes the CTA's scan inputs.  The inclusive CTA-wide \p aggregate of all inputs is computed for <em>thread</em><sub>0</sub>.
     *
     * The \p aggregate and \p cta_prefix_op are undefined in threads other than <em>thread</em><sub>0</sub>.
     *
     * \smemreuse
     *
     * \tparam ScanOp               <b>[inferred]</b> Binary scan functor type
     * \tparam CtaPrefixOp          <b>[inferred]</b> A call-back unary functor of the model </em>operator()(T local_local_aggregate)</em>
     */
    template <
        typename ScanOp,
        typename CtaPrefixOp>
    static __device__ __forceinline__ void InclusiveScan(
        SmemStorage     &smem_storage,                  ///< [in] Shared reference to opaque SmemStorage layout
        T               input,                          ///< [in] Calling thread's input item
        T               &output,                        ///< [out] Calling thread's output item (may be aliased to \p input)
        ScanOp          scan_op,                        ///< [in] Binary scan operator
        T               &local_aggregate,               ///< [out] <b>[<em>thread</em><sub>0</sub> only]</b> CTA-wide aggregate reduction of input items, exclusive of the \p cta_prefix_op value
        CtaPrefixOp     &cta_prefix_op)                 ///< [in-out] <b>[<em>thread</em><sub>0</sub> only]</b> A call-back unary functor of the model </em>operator()(T local_local_aggregate)</em> to be run <em>thread</em><sub>0</sub>.  When provided the CTA-wide aggregate of input items, this functor is expected to return the logical CTA-wide prefix to be applied during the scan operation.  Can be stateful.
    {
        if (WARP_SYNCHRONOUS)
        {
            // Short-circuit directly to warp scan
            WarpScan::InclusiveScan(
                smem_storage.warp_scan,
                input,
                output,
                scan_op,
                local_aggregate,
                cta_prefix_op);
        }
        else
        {
            // Place thread partial into shared memory raking grid
            T *placement_ptr = CtaRakingGrid::PlacementPtr(smem_storage.raking_grid);
            *placement_ptr = input;

            __syncthreads();

            // Reduce parallelism down to just raking threads
            if (threadIdx.x < RAKING_THREADS)
            {
                // Raking upsweep reduction in grid
                T *raking_ptr = CtaRakingGrid::RakingPtr(smem_storage.raking_grid);
                T raking_partial = ThreadReduce<RAKING_LENGTH>(raking_ptr, scan_op);

                // Warp synchronous scan
                WarpScan::ExclusiveScan(
                    smem_storage.warp_scan,
                    raking_partial,
                    raking_partial,
                    scan_op,
                    local_aggregate,
                    cta_prefix_op);

                // Exclusive raking downsweep scan
                ThreadScanExclusive<RAKING_LENGTH>(raking_ptr, raking_ptr, scan_op, raking_partial);

                if (!CtaRakingGrid::UNGUARDED)
                {
                    // CTA size isn't a multiple of warp size, so grab aggregate from the appropriate raking cell
                    local_aggregate = *CtaRakingGrid::PlacementPtr(smem_storage.raking_grid, 0, CTA_THREADS);
                }
            }

            __syncthreads();

            // Grab thread prefix from shared memory
            output = *placement_ptr;
        }
    }


    /**
     * \brief Computes an inclusive CTA-wide prefix scan using the specified binary scan functor.  Each thread contributes an array of consecutive input elements.  The functor \p cta_prefix_op is evaluated by <em>thread</em><sub>0</sub> to provide the preceding (or "base") value that logically prefixes the CTA's scan inputs.  The inclusive CTA-wide \p aggregate of all inputs is computed for <em>thread</em><sub>0</sub>.
     *
     * The \p aggregate and \p cta_prefix_op are undefined in threads other than <em>thread</em><sub>0</sub>.
     *
     * \smemreuse
     *
     * \tparam ITEMS_PER_THREAD     <b>[inferred]</b> The number of consecutive items partitioned onto each thread.
     * \tparam ScanOp               <b>[inferred]</b> Binary scan functor type
     * \tparam CtaPrefixOp          <b>[inferred]</b> A call-back unary functor of the model </em>operator()(T local_local_aggregate)</em>
     */
    template <
        int             ITEMS_PER_THREAD,
        typename        ScanOp,
        typename        CtaPrefixOp>
    static __device__ __forceinline__ void InclusiveScan(
        SmemStorage     &smem_storage,                  ///< [in] Shared reference to opaque SmemStorage layout
        T               (&input)[ITEMS_PER_THREAD],     ///< [in] Calling thread's input items
        T               (&output)[ITEMS_PER_THREAD],    ///< [out] Calling thread's output items (may be aliased to \p input)
        ScanOp          scan_op,                        ///< [in] Binary scan operator
        T               &local_aggregate,               ///< [out] <b>[<em>thread</em><sub>0</sub> only]</b> CTA-wide aggregate reduction of input items, exclusive of the \p cta_prefix_op value
        CtaPrefixOp     &cta_prefix_op)                 ///< [in-out] <b>[<em>thread</em><sub>0</sub> only]</b> A call-back unary functor of the model </em>operator()(T local_local_aggregate)</em> to be run <em>thread</em><sub>0</sub>.  When provided the CTA-wide aggregate of input items, this functor is expected to return the logical CTA-wide prefix to be applied during the scan operation.  Can be stateful.
    {
        // Reduce consecutive thread items in registers
        T thread_partial = ThreadReduce(input, scan_op);

        // Exclusive CTA-scan
        ExclusiveScan(smem_storage, thread_partial, thread_partial, scan_op, local_aggregate, cta_prefix_op);

        // Inclusive scan in registers with prefix
        ThreadScanInclusive(input, output, scan_op, thread_partial);
    }


    /**
     * \brief Computes an inclusive CTA-wide prefix scan using the specified binary scan functor.  Each thread contributes one input element.
     *
     * \smemreuse
     *
     * \tparam ScanOp               <b>[inferred]</b> Binary scan functor type
     */
    template <typename ScanOp>
    static __device__ __forceinline__ void InclusiveScan(
        SmemStorage     &smem_storage,                  ///< [in] Shared reference to opaque SmemStorage layout
        T               input,                          ///< [in] Calling thread's input item
        T               &output,                        ///< [out] Calling thread's output item (may be aliased to \p input)
        ScanOp          scan_op)                        ///< [in] Binary scan operator
    {
        T local_aggregate;
        InclusiveScan(smem_storage, input, output, scan_op, local_aggregate);
    }


    /**
     * \brief Computes an inclusive CTA-wide prefix scan using the specified binary scan functor.  Each thread contributes an array of consecutive input elements.
     *
     * \smemreuse
     *
     * \tparam ITEMS_PER_THREAD     <b>[inferred]</b> The number of consecutive items partitioned onto each thread.
     * \tparam ScanOp               <b>[inferred]</b> Binary scan functor type
     */
    template <
        int             ITEMS_PER_THREAD,
        typename        ScanOp>
    static __device__ __forceinline__ void InclusiveScan(
        SmemStorage     &smem_storage,                  ///< [in] Shared reference to opaque SmemStorage layout
        T               (&input)[ITEMS_PER_THREAD],     ///< [in] Calling thread's input items
        T               (&output)[ITEMS_PER_THREAD],    ///< [out] Calling thread's output items (may be aliased to \p input)
        ScanOp          scan_op)                        ///< [in] Binary scan operator
    {
        // Reduce consecutive thread items in registers
        T thread_partial = ThreadReduce(input, scan_op);

        // Exclusive CTA-scan
        ExclusiveScan(smem_storage, thread_partial, thread_partial, scan_op);

        // Inclusive scan in registers with prefix
        ThreadScanInclusive(input, output, scan_op, thread_partial, (threadIdx.x != 0));
    }


    //@}
    /******************************************************************//**
     * \name Inclusive prefix sums
     *********************************************************************/
    //@{


    /**
     * \brief Computes an inclusive CTA-wide prefix scan using the specified binary scan functor.  Each thread contributes one input element.  The inclusive CTA-wide \p aggregate of all inputs is computed for <em>thread</em><sub>0</sub>.
     *
     * The \p aggregate is undefined in threads other than <em>thread</em><sub>0</sub>.
     *
     * \smemreuse
     */
    static __device__ __forceinline__ void InclusiveSum(
        SmemStorage     &smem_storage,                  ///< [in] Shared reference to opaque SmemStorage layout
        T               input,                          ///< [in] Calling thread's input item
        T               &output,                        ///< [out] Calling thread's output item (may be aliased to \p input)
        T               &local_aggregate)               ///< [out] <b>[<em>thread</em><sub>0</sub> only]</b> CTA-wide aggregate reduction of input items
    {
        if (WARP_SYNCHRONOUS)
        {
            // Short-circuit directly to warp scan
            WarpScan::InclusiveSum(
                smem_storage.warp_scan,
                input,
                output,
                local_aggregate);
        }
        else
        {
            // Raking scan
            Sum<T> scan_op;

            // Place thread partial into shared memory raking grid
            T *placement_ptr = CtaRakingGrid::PlacementPtr(smem_storage.raking_grid);
            *placement_ptr = input;

            __syncthreads();

            // Reduce parallelism down to just raking threads
            if (threadIdx.x < RAKING_THREADS)
            {
                // Raking upsweep reduction in grid
                T *raking_ptr = CtaRakingGrid::RakingPtr(smem_storage.raking_grid);
                T raking_partial = ThreadReduce<RAKING_LENGTH>(raking_ptr, scan_op);

                // Exclusive warp synchronous scan
                WarpScan::ExclusiveSum(
                    smem_storage.warp_scan,
                    raking_partial,
                    raking_partial,
                    local_aggregate);

                // Exclusive raking downsweep scan
                ThreadScanExclusive<RAKING_LENGTH>(raking_ptr, raking_ptr, scan_op, raking_partial, (threadIdx.x != 0));

                if (!CtaRakingGrid::UNGUARDED)
                {
                    // CTA size isn't a multiple of warp size, so grab aggregate from the appropriate raking cell
                    local_aggregate = *CtaRakingGrid::PlacementPtr(smem_storage.raking_grid, 0, CTA_THREADS);
                }
            }

            __syncthreads();

            // Grab thread prefix from shared memory
            output = *placement_ptr;
        }
    }


    /**
     * \brief Computes an inclusive CTA-wide prefix scan using the specified binary scan functor.  Each thread contributes an array of consecutive input elements.  The inclusive CTA-wide \p aggregate of all inputs is computed for <em>thread</em><sub>0</sub>.
     *
     * The \p aggregate is undefined in threads other than <em>thread</em><sub>0</sub>.
     *
     * \smemreuse
     *
     * \tparam ITEMS_PER_THREAD     <b>[inferred]</b> The number of consecutive items partitioned onto each thread.
     * \tparam ScanOp               <b>[inferred]</b> Binary scan functor type
     */
    template <int ITEMS_PER_THREAD>
    static __device__ __forceinline__ void InclusiveSum(
        SmemStorage     &smem_storage,                  ///< [in] Shared reference to opaque SmemStorage layout
        T               (&input)[ITEMS_PER_THREAD],     ///< [in] Calling thread's input items
        T               (&output)[ITEMS_PER_THREAD],    ///< [out] Calling thread's output items (may be aliased to \p input)
        T               &local_aggregate)               ///< [out] <b>[<em>thread</em><sub>0</sub> only]</b> CTA-wide aggregate reduction of input items
    {
        // Reduce consecutive thread items in registers
        Sum<T> scan_op;
        T thread_partial = ThreadReduce(input, scan_op);

        // Exclusive CTA-scan
        ExclusiveSum(smem_storage, thread_partial, thread_partial, local_aggregate);

        // Inclusive scan in registers with prefix
        ThreadScanInclusive(input, output, scan_op, thread_partial, (threadIdx.x != 0));
    }


    /**
     * \brief Computes an inclusive CTA-wide prefix scan using the specified binary scan functor.  Each thread contributes one input element.  The functor \p cta_prefix_op is evaluated by <em>thread</em><sub>0</sub> to provide the preceding (or "base") value that logically prefixes the CTA's scan inputs.  The inclusive CTA-wide \p aggregate of all inputs is computed for <em>thread</em><sub>0</sub>.
     *
     * The \p aggregate and \p cta_prefix_op are undefined in threads other than <em>thread</em><sub>0</sub>.
     *
     * \smemreuse
     *
     * \tparam CtaPrefixOp          <b>[inferred]</b> A call-back unary functor of the model </em>operator()(T local_local_aggregate)</em>
     */
    template <typename CtaPrefixOp>
    static __device__ __forceinline__ void InclusiveSum(
        SmemStorage     &smem_storage,                  ///< [in] Shared reference to opaque SmemStorage layout
        T               input,                          ///< [in] Calling thread's input item
        T               &output,                        ///< [out] Calling thread's output item (may be aliased to \p input)
        T               &local_aggregate,               ///< [out] <b>[<em>thread</em><sub>0</sub> only]</b> CTA-wide aggregate reduction of input items, exclusive of the \p cta_prefix_op value
        CtaPrefixOp     &cta_prefix_op)                 ///< [in-out] <b>[<em>thread</em><sub>0</sub> only]</b> A call-back unary functor of the model </em>operator()(T local_local_aggregate)</em> to be run <em>thread</em><sub>0</sub>.  When provided the CTA-wide aggregate of input items, this functor is expected to return the logical CTA-wide prefix to be applied during the scan operation.  Can be stateful.
    {
        if (WARP_SYNCHRONOUS)
        {
            // Short-circuit directly to warp scan
            WarpScan::InclusiveSum(
                smem_storage.warp_scan,
                input,
                output,
                local_aggregate,
                cta_prefix_op);
        }
        else
        {
            // Raking scan
            Sum<T> scan_op;

            // Place thread partial into shared memory raking grid
            T *placement_ptr = CtaRakingGrid::PlacementPtr(smem_storage.raking_grid);
            *placement_ptr = input;

            __syncthreads();

            // Reduce parallelism down to just raking threads
            if (threadIdx.x < RAKING_THREADS)
            {
                // Raking upsweep reduction in grid
                T *raking_ptr = CtaRakingGrid::RakingPtr(smem_storage.raking_grid);
                T raking_partial = ThreadReduce<RAKING_LENGTH>(raking_ptr, scan_op);

                // Warp synchronous scan
                WarpScan::ExclusiveSum(
                    smem_storage.warp_scan,
                    raking_partial,
                    raking_partial,
                    local_aggregate,
                    cta_prefix_op);

                // Exclusive raking downsweep scan
                ThreadScanExclusive<RAKING_LENGTH>(raking_ptr, raking_ptr, scan_op, raking_partial);

                if (!CtaRakingGrid::UNGUARDED)
                {
                    // CTA size isn't a multiple of warp size, so grab aggregate from the appropriate raking cell
                    local_aggregate = *CtaRakingGrid::PlacementPtr(smem_storage.raking_grid, 0, CTA_THREADS);
                }
            }

            __syncthreads();

            // Grab thread prefix from shared memory
            output = *placement_ptr;
        }
    }


    /**
     * \brief Computes an inclusive CTA-wide prefix scan using the specified binary scan functor.  Each thread contributes an array of consecutive input elements.  The functor \p cta_prefix_op is evaluated by <em>thread</em><sub>0</sub> to provide the preceding (or "base") value that logically prefixes the CTA's scan inputs.  The inclusive CTA-wide \p aggregate of all inputs is computed for <em>thread</em><sub>0</sub>.
     *
     * The \p aggregate and \p cta_prefix_op are undefined in threads other than <em>thread</em><sub>0</sub>.
     *
     * \smemreuse
     *
     * \tparam ITEMS_PER_THREAD     <b>[inferred]</b> The number of consecutive items partitioned onto each thread.
     * \tparam CtaPrefixOp          <b>[inferred]</b> A call-back unary functor of the model </em>operator()(T local_local_aggregate)</em>
     */
    template <
        int ITEMS_PER_THREAD,
        typename CtaPrefixOp>
    static __device__ __forceinline__ void InclusiveSum(
        SmemStorage     &smem_storage,                  ///< [in] Shared reference to opaque SmemStorage layout
        T               (&input)[ITEMS_PER_THREAD],     ///< [in] Calling thread's input items
        T               (&output)[ITEMS_PER_THREAD],    ///< [out] Calling thread's output items (may be aliased to \p input)
        T               &local_aggregate,               ///< [out] <b>[<em>thread</em><sub>0</sub> only]</b> CTA-wide aggregate reduction of input items, exclusive of the \p cta_prefix_op value
        CtaPrefixOp     &cta_prefix_op)                 ///< [in-out] <b>[<em>thread</em><sub>0</sub> only]</b> A call-back unary functor of the model </em>operator()(T local_local_aggregate)</em> to be run <em>thread</em><sub>0</sub>.  When provided the CTA-wide aggregate of input items, this functor is expected to return the logical CTA-wide prefix to be applied during the scan operation.  Can be stateful.
    {
        // Reduce consecutive thread items in registers
        Sum<T> scan_op;
        T thread_partial = ThreadReduce(input, scan_op);

        // Exclusive CTA-scan
        ExclusiveSum(smem_storage, thread_partial, thread_partial, local_aggregate, cta_prefix_op);

        // Inclusive scan in registers with prefix
        ThreadScanInclusive(input, output, scan_op, thread_partial);
    }


    /**
     * \brief Computes an inclusive CTA-wide prefix scan using the specified binary scan functor.  Each thread contributes one input element.
     *
     * \smemreuse
     */
    static __device__ __forceinline__ void InclusiveSum(
        SmemStorage     &smem_storage,                  ///< [in] Shared reference to opaque SmemStorage layout
        T               input,                          ///< [in] Calling thread's input item
        T               &output)                        ///< [out] Calling thread's output item (may be aliased to \p input)
    {
        T local_aggregate;
        InclusiveSum(smem_storage, input, output, local_aggregate);
    }


    /**
     * \brief Computes an inclusive CTA-wide prefix scan using the specified binary scan functor.  Each thread contributes an array of consecutive input elements.
     *
     * \smemreuse
     *
     * \tparam ITEMS_PER_THREAD     <b>[inferred]</b> The number of consecutive items partitioned onto each thread.
     * \tparam ScanOp               <b>[inferred]</b> Binary scan functor type
     */
    template <int ITEMS_PER_THREAD>
    static __device__ __forceinline__ void InclusiveSum(
        SmemStorage     &smem_storage,                  ///< [in] Shared reference to opaque SmemStorage layout
        T               (&input)[ITEMS_PER_THREAD],     ///< [in] Calling thread's input items
        T               (&output)[ITEMS_PER_THREAD])    ///< [out] Calling thread's output items (may be aliased to \p input)
    {
        // Reduce consecutive thread items in registers
        Sum<T> scan_op;
        T thread_partial = ThreadReduce(input, scan_op);

        // Exclusive CTA-scan
        ExclusiveSum(smem_storage, thread_partial, thread_partial);

        // Inclusive scan in registers with prefix
        ThreadScanInclusive(input, output, scan_op, thread_partial, (threadIdx.x != 0));
    }

    //@}        // Inclusive prefix sums

};

/** @} */       // SimtCoop

} // namespace cub
CUB_NS_POSTFIX
