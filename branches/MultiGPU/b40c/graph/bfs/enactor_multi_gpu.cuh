/******************************************************************************
 * Copyright 2010 Duane Merrill
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
 ******************************************************************************/

/******************************************************************************
 * Multi-GPU out-of-core BFS implementation (BFS level grid launch)
 ******************************************************************************/

#pragma once

#include <vector>

#include <b40c/util/cuda_properties.cuh>
#include <b40c/util/spine.cuh>
#include <b40c/util/kernel_runtime_stats.cuh>
#include <b40c/util/cta_work_progress.cuh>

#include <b40c/graph/bfs/enactor_base.cuh>
#include <b40c/graph/bfs/problem_type.cuh>

#include <b40c/graph/bfs/expand_atomic/kernel.cuh>
#include <b40c/graph/bfs/expand_atomic/kernel_policy.cuh>

#include <b40c/graph/bfs/partition_compact/policy.cuh>
#include <b40c/graph/bfs/partition_compact/upsweep/kernel.cuh>
#include <b40c/graph/bfs/partition_compact/upsweep/kernel_policy.cuh>
#include <b40c/graph/bfs/partition_compact/downsweep/kernel.cuh>
#include <b40c/graph/bfs/partition_compact/downsweep/kernel_policy.cuh>

namespace b40c {
namespace graph {
namespace bfs {



/**
 * Multi-GPU out-of-core BFS implementation (BFS level grid launch)
 *  
 * Each iteration is performed by its own kernel-launch.
 *
 * All GPUs must be of the same SM architectural version (e.g., SM2.0).
 */
class EnactorMultiGpu : public EnactorBase
{

protected:

	//---------------------------------------------------------------------
	// Helper Structures
	//---------------------------------------------------------------------

	/**
	 * Management structure for each GPU
	 */
	struct GpuControlBlock
	{
		//---------------------------------------------------------------------
		// Members
		//---------------------------------------------------------------------

		bool DEBUG;

		// GPU index
		int gpu;

		// GPU cuda properties
		util::CudaProperties cuda_props;

		// Queue size counters and accompanying functionality
		util::CtaWorkProgressLifetime work_progress;

		// Partitioning spine storage
		util::Spine spine;
		int spine_elements;

		int expand_grid_size;			// Expansion grid size
		int partition_grid_size;		// Partition/partition grid size

		long long iteration;			// BFS iteration
		int selector;					// Queue selector
		int queue_index;				// Work stealing/queue index
		long long queue_length;			// Current queue size

		// Kernel duty stats
		util::KernelRuntimeStatsLifetime expand_kernel_stats;
		util::KernelRuntimeStatsLifetime compact_kernel_stats;


		//---------------------------------------------------------------------
		// Methods
		//---------------------------------------------------------------------

		/**
		 * Constructor
		 */
		GpuControlBlock(int gpu, bool DEBUG = false) :
			gpu(gpu),
			DEBUG(DEBUG),
			cuda_props(gpu),
			spine(true),				// Host-mapped spine
			spine_elements(0),
			expand_grid_size(0),
			partition_grid_size(0),
			iteration(0),
			selector(0),
			queue_index(0),
			queue_length(0)
		{}


		/**
		 * Returns the default maximum number of threadblocks that should be
		 * launched for this GPU.
		 */
		int MaxGridSize(int cta_occupancy, int max_grid_size)
		{
			if (max_grid_size <= 0) {
				// No override: Fully populate all SMs
				max_grid_size = cuda_props.device_props.multiProcessorCount * cta_occupancy;
			}

			return max_grid_size;
		}


		/**
		 * Setup / lazy initialization
		 */
	    template <typename ExpandPolicy, typename PartitionPolicy>
		cudaError_t Setup(int max_grid_size, int num_gpus)
		{
	    	cudaError_t retval = cudaSuccess;

			do {
		    	// Determine grid size(s)
				int expand_min_occupancy 		= ExpandPolicy::CTA_OCCUPANCY;
				expand_grid_size 				= MaxGridSize(expand_min_occupancy, max_grid_size);

				int partition_min_occupancy		= B40C_MIN((int) PartitionPolicy::Upsweep::CTA_OCCUPANCY, (int) PartitionPolicy::Downsweep::CTA_OCCUPANCY);
				partition_grid_size 			= MaxGridSize(partition_min_occupancy, max_grid_size);

				// Setup partitioning spine
				spine_elements = (partition_grid_size * PartitionPolicy::Upsweep::BINS) + 1;
				if (retval = spine.template Setup<typename PartitionPolicy::SizeT>(spine_elements)) break;

				if (DEBUG) printf("Gpu %d expand min occupancy %d, grid size %d\n",
					gpu, expand_min_occupancy, expand_grid_size);
				if (DEBUG) printf("Gpu %d partition min occupancy %d, grid size %d, spine elements %d\n",
					gpu, partition_min_occupancy, partition_grid_size, spine_elements);

				// Setup work progress
				if (retval = work_progress.Setup()) break;

			} while (0);

			// Reset statistics
			iteration = 0;
			selector = 0;
			queue_index = 0;
			queue_length = 0;

			return retval;
		}


	    /**
	     * Updates queue length from work progress
	     *
	     * (SizeT may be different for each graph search)
	     */
		template <typename SizeT>
	    cudaError_t UpdateQueueLength()
	    {
	    	SizeT length;
	    	cudaError_t retval = work_progress.GetQueueLength(iteration, length);
	    	queue_length = length;

	    	return retval;
	    }
	};

	//---------------------------------------------------------------------
	// Members
	//---------------------------------------------------------------------

	// Vector of GpuControlBlocks (one for each GPU)
	std::vector <GpuControlBlock *> control_blocks;

	bool DEBUG2;

	//---------------------------------------------------------------------
	// Utility Methods
	//---------------------------------------------------------------------


public: 	
	
	/**
	 * Constructor
	 */
	EnactorMultiGpu(bool DEBUG = false) :
		EnactorBase(DEBUG),
		DEBUG2(false)
	{}


	/**
	 * Resets control blocks
	 */
	void ResetControlBlocks()
	{
		// Cleanup control blocks on the heap
		for (typename std::vector<GpuControlBlock*>::iterator itr = control_blocks.begin();
			itr != control_blocks.end();
			itr++)
		{
			if (*itr) delete (*itr);
		}

		control_blocks.clear();
	}


	/**
	 * Destructor
	 */
	virtual ~EnactorMultiGpu()
	{
		ResetControlBlocks();
	}


    /**
     * Obtain statistics about the last BFS search enacted 
     */
	template <typename VertexId>
    void GetStatistics(
    	long long &total_queued,
    	VertexId &search_depth,
    	double &avg_live)
    {
		// TODO
    	total_queued = 0;
    	search_depth = 0;
    	avg_live = 0;
    }


	/**
	 * Search setup / lazy initialization
	 */
    template <
    	typename ExpandPolicy,
    	typename PartitionPolicy,
    	typename CsrProblem>
	cudaError_t Setup(
		CsrProblem 		&csr_problem,
		int 			max_grid_size)
    {
    	cudaError_t retval = cudaSuccess;

    	do {
			// Check if last run was with an different number of GPUs (in which
			// case the control blocks are all misconfigured)
			if (control_blocks.size() != csr_problem.num_gpus) {

				ResetControlBlocks();

				for (volatile int i = 0; i < csr_problem.num_gpus; i++) {

					// Set device
					if (retval = util::B40CPerror(cudaSetDevice(csr_problem.graph_slices[i]->gpu),
						"EnactorMultiGpu cudaSetDevice failed", __FILE__, __LINE__)) break;

					control_blocks.push_back(
						new GpuControlBlock(csr_problem.graph_slices[i]->gpu,
						DEBUG));
				}
			}

			// Setup control blocks
			for (volatile int i = 0; i < csr_problem.num_gpus; i++) {

				// Set device
				if (retval = util::B40CPerror(cudaSetDevice(csr_problem.graph_slices[i]->gpu),
					"EnactorMultiGpu cudaSetDevice failed", __FILE__, __LINE__)) break;

				if (retval = control_blocks[i]->template Setup<ExpandPolicy, PartitionPolicy>(
					max_grid_size, csr_problem.num_gpus)) break;
			}
			if (retval) break;

    	} while (0);

    	return retval;
    }


	/**
	 * Enacts a breadth-first-search on the specified graph problem.
	 *
	 * @return cudaSuccess on success, error enumeration otherwise
	 */
    template <
    	typename ExpandPolicy,
    	typename PartitionPolicy,
    	bool INSTRUMENT,
    	typename CsrProblem>
	cudaError_t EnactSearch(
		CsrProblem 							&csr_problem,
		typename CsrProblem::VertexId 		src,
		int 								max_grid_size = 0)
	{
		typedef typename CsrProblem::VertexId			VertexId;
		typedef typename CsrProblem::SizeT				SizeT;
		typedef typename CsrProblem::GraphSlice			GraphSlice;

		typedef typename PartitionPolicy::Upsweep		PartitionUpsweep;
		typedef typename PartitionPolicy::Spine			PartitionSpine;
		typedef typename PartitionPolicy::Downsweep		PartitionDownsweep;

		cudaError_t retval = cudaSuccess;

		do {

			// Number of partitioning bins per GPU (in case we over-partition)
			int bins_per_gpu = PartitionPolicy::Upsweep::BINS / csr_problem.num_gpus;
			printf("Partition bins per GPU: %d\n", bins_per_gpu);

			// Search setup / lazy initialization
			if (retval = Setup<ExpandPolicy, PartitionPolicy>(csr_problem, max_grid_size)) break;


			//---------------------------------------------------------------------
			// Expand work queues (first iteration)
			//---------------------------------------------------------------------

			for (volatile int i = 0; i < csr_problem.num_gpus; i++) {

				GpuControlBlock *control 	= control_blocks[i];
				GraphSlice *slice 			= csr_problem.graph_slices[i];

				// Set device
				if (retval = util::B40CPerror(cudaSetDevice(control->gpu),
					"EnactorMultiGpu cudaSetDevice failed", __FILE__, __LINE__)) break;

				bool owns_source = (control->gpu == csr_problem.GpuIndex(src));
				if (owns_source) {
					printf("GPU %d owns source %d\n", control->gpu, src);
				}

				// Expansion
				expand_atomic::Kernel<ExpandPolicy>
						<<<control->expand_grid_size, ExpandPolicy::THREADS, 0, slice->stream>>>(
					(owns_source) ? src : -1,													// source
					(owns_source) ? 1 : 0,														// num_elements
					control->iteration,
					control->queue_index,
					csr_problem.num_gpus,
					NULL,																		// d_done (not used)
					slice->frontier_queues.d_keys[control->selector],							// sorted in
					slice->frontier_queues.d_keys[control->selector ^ 1],						// expanded out
					(VertexId *) slice->frontier_queues.d_values[control->selector],			// sorted parents in
					(VertexId *) slice->frontier_queues.d_values[control->selector ^ 1],		// expanded parents out
					slice->d_column_indices,
					slice->d_row_offsets,
					slice->d_source_path,
					control->work_progress,
					control->expand_kernel_stats);

				if (DEBUG && (retval = util::B40CPerror(cudaDeviceSynchronize(),
					"EnactorMultiGpu expand_atomic::Kernel failed", __FILE__, __LINE__))) break;

				control->selector ^= 1;
				control->iteration++;
				control->queue_index++;
			}
			if (retval) break;

			// BFS passes
			while (true) {

				//---------------------------------------------------------------------
				// Synchronization point
				//---------------------------------------------------------------------

				bool done = true;
				for (volatile int i = 0; i < csr_problem.num_gpus; i++) {

					GpuControlBlock *control 	= control_blocks[i];
					GraphSlice *slice 			= csr_problem.graph_slices[i];

					// Set device
					if (retval = util::B40CPerror(cudaSetDevice(control->gpu),
						"EnactorMultiGpu cudaSetDevice failed", __FILE__, __LINE__)) break;

					// Update queue length
					if (retval = control->template UpdateQueueLength<SizeT>()) break;

					printf("Iteration %lld GPU %d partition enqueued %lld\n",
						(long long) control->iteration - 1,
						control->gpu,
						(long long) control->queue_length);

					// Check if this gpu is not done
					if (control->queue_length) done = false;

					if (DEBUG2) {
						printf("Expanded queue on gpu %d (%lld elements):\n",
							control->gpu, (long long) control->queue_length);
						DisplayDeviceResults(
							slice->frontier_queues.d_keys[control->selector],
							control->queue_length);
/*
						printf("Source distance vector on gpu %d:\n", control->gpu);
						DisplayDeviceResults(
							slice->d_source_path,
							slice->nodes);
*/
					}
				}
				if (retval) break;

				// Check if all done in all GPUs
				if (done) break;
				printf("\n");

				//---------------------------------------------------------------------
				// Partition/compact work queues
				//---------------------------------------------------------------------

				for (volatile int i = 0; i < csr_problem.num_gpus; i++) {

					GpuControlBlock *control 	= control_blocks[i];
					GraphSlice *slice 			= csr_problem.graph_slices[i];

					// Set device
					if (retval = util::B40CPerror(cudaSetDevice(control->gpu),
						"EnactorMultiGpu cudaSetDevice failed", __FILE__, __LINE__)) break;

					// Upsweep
					partition_compact::upsweep::Kernel<PartitionUpsweep>
							<<<control->partition_grid_size, PartitionUpsweep::THREADS, 0, slice->stream>>>(
						control->iteration,
						slice->frontier_queues.d_keys[control->selector],
						slice->d_keep,
						(SizeT *) control->spine(),
						slice->d_collision_cache,
						control->work_progress,
						control->compact_kernel_stats);

					if (DEBUG && (retval = util::B40CPerror(cudaDeviceSynchronize(),
						"EnactorMultiGpu partition_compact::upsweep::Kernel failed", __FILE__, __LINE__))) break;

					if (DEBUG2) {
						printf("Presorted spine on gpu %d (%lld elements):\n",
							control->gpu,
							(long long) control->spine_elements);
						DisplayDeviceResults(
							(SizeT *) control->spine.d_spine,
							control->spine_elements);
					}

					// Spine
					PartitionPolicy::SpineKernel()<<<1, PartitionSpine::THREADS, 0, slice->stream>>>(
						(SizeT*) control->spine(),
						(SizeT*) control->spine(),
						control->spine_elements);

					if (DEBUG && (retval = util::B40CPerror(cudaDeviceSynchronize(),
						"EnactorMultiGpu SpineKernel failed", __FILE__, __LINE__))) break;

					if (DEBUG2) {
						printf("Postsorted spine on gpu %d (%lld elements):\n",
							control->gpu,
							(long long) control->spine_elements);
						DisplayDeviceResults(
							(SizeT *) control->spine.d_spine,
							control->spine_elements);
					}

					// Downsweep
					partition_compact::downsweep::Kernel<PartitionDownsweep>
							<<<control->partition_grid_size, PartitionDownsweep::THREADS, 0, slice->stream>>>(
						control->iteration,
						slice->frontier_queues.d_keys[control->selector],						// expanded in
						slice->frontier_queues.d_keys[control->selector ^ 1],					// partitioned out
						(VertexId *) slice->frontier_queues.d_values[control->selector],		// expanded parents in
						(VertexId *) slice->frontier_queues.d_values[control->selector ^ 1],	// partitioned parents out
						slice->d_keep,
						(SizeT *) control->spine(),
						control->work_progress,
						control->compact_kernel_stats);

					if (DEBUG && (retval = util::B40CPerror(cudaDeviceSynchronize(),
						"EnactorMultiGpu DownsweepKernel failed", __FILE__, __LINE__))) break;

					control->selector ^= 1;
				}
				if (retval) break;


				//---------------------------------------------------------------------
				// Synchronization point (to make spines coherent)
				//---------------------------------------------------------------------

				done = true;
				for (volatile int i = 0; i < csr_problem.num_gpus; i++) {

					GpuControlBlock *control 	= control_blocks[i];
					GraphSlice *slice 			= csr_problem.graph_slices[i];

					if (retval = util::B40CPerror(cudaSetDevice(control->gpu),
						"EnactorMultiGpu cudaSetDevice failed", __FILE__, __LINE__)) break;
					if (retval = util::B40CPerror(cudaDeviceSynchronize(),
						"EnactorMultiGpu cudaDeviceSynchronize failed", __FILE__, __LINE__)) break;

					SizeT *spine = (SizeT *) control->spine.h_spine;
					if (spine[control->spine_elements - 1]) done = false;

					printf("Iteration %lld GPU %d partition compacted %lld\n",
						(long long) control->iteration,
						control->gpu,
						(long long) spine[control->spine_elements - 1]);

					if (DEBUG2) {
						printf("Compacted queue on gpu %d (%lld elements):\n",
							control->gpu,
							(long long) spine[control->spine_elements - 1]);
						DisplayDeviceResults(
							slice->frontier_queues.d_keys[control->selector],
							spine[control->spine_elements - 1]);
/*
						printf("Source distance vector on gpu %d:\n", control->gpu);
						DisplayDeviceResults(
							slice->d_source_path,
							slice->nodes);
*/
					}
				}
				if (retval) break;

				// Check if all done in all GPUs
				if (done) break;

				if (DEBUG2) printf("---------------------------------------------------------");
				printf("\n");

				//---------------------------------------------------------------------
				// Expand work queues
				//---------------------------------------------------------------------

				for (volatile int i = 0; i < csr_problem.num_gpus; i++) {

					GpuControlBlock *control 	= control_blocks[i];
					GraphSlice *slice 			= csr_problem.graph_slices[i];

					// Set device
					if (retval = util::B40CPerror(cudaSetDevice(control->gpu),
						"EnactorMultiGpu cudaSetDevice failed", __FILE__, __LINE__)) break;

					// Stream in and expand inputs from all gpus (including ourselves)
					for (volatile int j = 0; j < csr_problem.num_gpus; j++) {

						int peer 							= j % csr_problem.num_gpus;
						GpuControlBlock *peer_control 		= control_blocks[peer];
						GraphSlice *peer_slice 				= csr_problem.graph_slices[peer];
						SizeT *peer_spine 					= (SizeT*) peer_control->spine.h_spine;

						SizeT queue_offset 	= peer_spine[bins_per_gpu * i * peer_control->partition_grid_size];
						SizeT queue_oob 	= peer_spine[bins_per_gpu * (i + 1) * peer_control->partition_grid_size];
						SizeT num_elements	= queue_oob - queue_offset;

						if (DEBUG2) {
							printf("Gpu %d getting %d from gpu %d selector %d, queue_offset: %d @ %d, queue_oob: %d @ %d\n",
								i,
								num_elements,
								peer,
								peer_control->selector,
								queue_offset,
								bins_per_gpu * i * peer_control->partition_grid_size,
								queue_oob,
								bins_per_gpu * (i + 1) * peer_control->partition_grid_size);
							fflush(stdout);
						}

						expand_atomic::Kernel<ExpandPolicy>
								<<<control->expand_grid_size, ExpandPolicy::THREADS, 0, slice->stream>>>(
							-1,							// source (not used)
							num_elements,
							control->iteration,
							control->queue_index,
							csr_problem.num_gpus,
							NULL,						// d_done (not used)
							peer_slice->frontier_queues.d_keys[control->selector] + queue_offset,
							slice->frontier_queues.d_keys[control->selector ^ 1],
							(VertexId *) peer_slice->frontier_queues.d_values[control->selector] + queue_offset,
							(VertexId *) slice->frontier_queues.d_values[control->selector ^ 1],
							slice->d_column_indices,
							slice->d_row_offsets,
							slice->d_source_path,
							control->work_progress,
							control->expand_kernel_stats);

						if (DEBUG && (retval = util::B40CPerror(cudaDeviceSynchronize(),
							"EnactorMultiGpu expand_atomic::Kernel failed", __FILE__, __LINE__))) break;

						control->queue_index++;
					}

					control->selector ^= 1;
					control->iteration++;
				}
				if (retval) break;
			}

		} while (0);

		return retval;
	}


	/**
	 * Enacts a breadth-first-search on the specified graph problem.
	 *
	 * @return cudaSuccess on success, error enumeration otherwise
	 */
    template <bool INSTRUMENT, typename CsrProblem>
	cudaError_t EnactSearch(
		CsrProblem 							&csr_problem,
		typename CsrProblem::VertexId 		src,
		int 								max_grid_size = 0)
	{
    	// Maximum two GPUs
    	static const int LOG_MAX_GPUS = 1;

    	// Enforce power-of-two gpus
		if (csr_problem.num_gpus & (csr_problem.num_gpus - 1)) {		// clear the least significant bit set
			printf("Only a power-of-two number of GPUs are supported");
			return cudaErrorInvalidConfiguration;
		}

		if (this->cuda_props.device_sm_version >= 200) {

			// Expansion kernel config
			typedef expand_atomic::KernelPolicy<
				typename CsrProblem::ProblemType,
				200,
				INSTRUMENT, 			// INSTRUMENT
				0, 						// SATURATION_QUIT
				false, 					// DEQUEUE_PROBLEM_SIZE
				true,					// ENQUEUE_BY_ITERATION
				8,						// CTA_OCCUPANCY
				7,						// LOG_THREADS
				0,						// LOG_LOAD_VEC_SIZE
				0,						// LOG_LOADS_PER_TILE
				5,						// LOG_RAKING_THREADS
				util::io::ld::NONE,		// QUEUE_READ_MODIFIER,
				util::io::ld::NONE,		// COLUMN_READ_MODIFIER,
				util::io::ld::cg,		// ROW_OFFSET_ALIGNED_READ_MODIFIER,
				util::io::ld::NONE,		// ROW_OFFSET_UNALIGNED_READ_MODIFIER,
				util::io::st::NONE,		// QUEUE_WRITE_MODIFIER,
				true,					// WORK_STEALING
				6> ExpandPolicy;		// LOG_SCHEDULE_GRANULARITY


			// Make sure we satisfy the tuning constraints in partition::[up|down]sweep::tuning_policy.cuh
			typedef partition_compact::Policy<
				// Problem Type
				typename CsrProblem::ProblemType,
				200,
				INSTRUMENT, 			// INSTRUMENT
				LOG_MAX_GPUS,			// LOG_BINS
				9,						// LOG_SCHEDULE_GRANULARITY
				util::io::ld::NONE,		// CACHE_MODIFIER
				util::io::st::NONE,		// CACHE_MODIFIER

				8,						// UPSWEEP_CTA_OCCUPANCY
				7,						// UPSWEEP_LOG_THREADS
				0,						// UPSWEEP_LOG_LOAD_VEC_SIZE
				2,						// UPSWEEP_LOG_LOADS_PER_TILE

				1,						// SPINE_CTA_OCCUPANCY
				7,						// SPINE_LOG_THREADS
				2,						// SPINE_LOG_LOAD_VEC_SIZE
				0,						// SPINE_LOG_LOADS_PER_TILE
				5,						// SPINE_LOG_RAKING_THREADS

				8,						// DOWNSWEEP_CTA_OCCUPANCY
				6,						// DOWNSWEEP_LOG_THREADS
				1,						// DOWNSWEEP_LOG_LOAD_VEC_SIZE
				2,						// DOWNSWEEP_LOG_LOADS_PER_CYCLE
				0,						// DOWNSWEEP_LOG_CYCLES_PER_TILE
				6> PartitionPolicy;		// DOWNSWEEP_LOG_RAKING_THREADS

			return EnactSearch<ExpandPolicy, PartitionPolicy, INSTRUMENT>(
				csr_problem, src, max_grid_size);

		} else {
			printf("Not yet tuned for this architecture\n");
			return cudaErrorInvalidConfiguration;
		}
	}

    
};



} // namespace bfs
} // namespace graph
} // namespace b40c