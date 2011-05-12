/******************************************************************************
 * 
 * Copyright 2010-2011 Duane Merrill
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
 * For more information, see our Google Code project site: 
 * http://code.google.com/p/back40computing/
 * 
 * Thanks!
 * 
 ******************************************************************************/

/******************************************************************************
 * WarpScan
 ******************************************************************************/

#pragma once

#include <b40c/util/operators.cuh>

namespace b40c {
namespace util {
namespace scan {



/**
 * Performs NUM_ELEMENTS steps of a Kogge-Stone style prefix scan.
 *
 * This procedure assumes that no explicit barrier synchronization is needed
 * between steps (i.e., warp-synchronous programming)
 */
template <
	int LOG_NUM_ELEMENTS,
	bool EXCLUSIVE = true,
	int STEPS = LOG_NUM_ELEMENTS>
struct WarpScan
{
	enum {
		NUM_ELEMENTS = 1 << LOG_NUM_ELEMENTS,
	};

	//---------------------------------------------------------------------
	// Helper Structures
	//---------------------------------------------------------------------

	// General iteration
	template <int OFFSET_LEFT, int WIDTH>
	struct Iterate
	{
		template <typename T, T ScanOp(const T&, const T&)>
		static __device__ __forceinline__ T Invoke(
			T exclusive_partial,
			volatile T warpscan[][NUM_ELEMENTS],
			int warpscan_tid)
		{
			warpscan[1][warpscan_tid] = exclusive_partial;
			T offset_partial = warpscan[1][warpscan_tid - OFFSET_LEFT];
			T inclusive_partial = ScanOp(offset_partial, exclusive_partial);

			return Iterate<OFFSET_LEFT * 2, WIDTH>::template Invoke<T, ScanOp>(
				inclusive_partial, warpscan, warpscan_tid);
		}
	};

	// Termination
	template <int WIDTH>
	struct Iterate<WIDTH, WIDTH>
	{
		template <typename T, T ScanOp(const T&, const T&)>
		static __device__ __forceinline__ T Invoke(
			T exclusive_partial, volatile T warpscan[][NUM_ELEMENTS], int warpscan_tid)
		{
			return exclusive_partial;
		}
	};


	//---------------------------------------------------------------------
	// Interface
	//---------------------------------------------------------------------

	/**
	 * Warpscan with the specified operator
	 */
	template <
		typename T,
		T ScanOp(const T&, const T&)>
	static __device__ __forceinline__ T Invoke(
		T current_partial,							// Input partial
		volatile T warpscan[][NUM_ELEMENTS],		// Smem for warpscanning.  Contains at least two segments of size NUM_ELEMENTS (the first being initialized to identity)
		int warpscan_tid = threadIdx.x)				// Thread's local index into a segment of NUM_ELEMENTS items
	{
		const int WIDTH = 1 << STEPS;
		T inclusive_partial = Iterate<1, WIDTH>::template Invoke<T, ScanOp>(
			current_partial, warpscan, warpscan_tid);

		if (EXCLUSIVE) {
			// Write out our inclusive partial
			warpscan[1][warpscan_tid] = inclusive_partial;

			// Return exclusive partial
			return warpscan[1][warpscan_tid - 1];

		} else {
			return inclusive_partial;
		}
	}


	/**
	 * Warpscan with the addition operator
	 */
	template <typename T>
	static __device__ __forceinline__ T Invoke(
		T current_partial,							// Input partial
		volatile T warpscan[][NUM_ELEMENTS],		// Smem for warpscanning.  Contains at least two segments of size NUM_ELEMENTS (the first being initialized to identity)
		int warpscan_tid = threadIdx.x)				// Thread's local index into a segment of NUM_ELEMENTS items
	{
		return Invoke<T, DefaultSum>(current_partial, warpscan, warpscan_tid);
	}


	/**
	 * Warpscan with the specified operator, returning the cumulative reduction
	 */
	template <
		typename T,
		T ScanOp(const T&, const T&)>
	static __device__ __forceinline__ T Invoke(
		T current_partial,							// Input partial
		T &total_reduction,							// Total reduction (out param)
		volatile T warpscan[][NUM_ELEMENTS],		// Smem for warpscanning.  Contains at least two segments of size NUM_ELEMENTS (the first being initialized to identity)
		int warpscan_tid = threadIdx.x)				// Thread's local index into a segment of NUM_ELEMENTS items
	{
		const int WIDTH = 1 << STEPS;
		T inclusive_partial = Iterate<1, WIDTH>::template Invoke<T, ScanOp>(
			current_partial, warpscan, warpscan_tid);

		// Write our inclusive partial and then set total to the last thread's inclusive partial
		warpscan[1][warpscan_tid] = inclusive_partial;
		total_reduction = warpscan[1][NUM_ELEMENTS - 1];

		if (EXCLUSIVE) {
			return warpscan[1][warpscan_tid - 1];
		} else {
			return inclusive_partial;
		}
	}

	/**
	 * Warpscan with the addition operator, returning the cumulative reduction
	 */
	template <typename T>
	static __device__ __forceinline__ T Invoke(
		T current_partial,							// Input partial
		T &total_reduction,							// Total reduction (out param)
		volatile T warpscan[][NUM_ELEMENTS],		// Smem for warpscanning.  Contains at least two segments of size NUM_ELEMENTS (the first being initialized to identity)
		int warpscan_tid = threadIdx.x)				// Thread's local index into a segment of NUM_ELEMENTS items
	{
		return Invoke<T, DefaultSum>(current_partial, total_reduction, warpscan, warpscan_tid);
	}
};



} // namespace scan
} // namespace util
} // namespace b40c
