/******************************************************************************
 * Copyright 2010 Duane Merrill
 * 
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 *	 http://www.apache.org/licenses/LICENSE-2.0
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
 * Simple test driver program for BFS graph traversal API.
 *
 * Useful for demonstrating how to integrate BFS traversal into your 
 * application. 
 ******************************************************************************/

#include <stdio.h> 
#include <string>
#include <deque>

// Utilities and correctness-checking
#include <test_utils.cu>

// Graph utils
#include <dimacs.cu>
#include <grid2d.cu>
#include <grid3d.cu>
#include <market.cu>
#include <metis.cu>
#include <random.cu>
#include <rr.cu>

// BFS enactor includes
#include <bfs_common.cu>
#include <bfs_csr_problem.cu>
//#include <bfs_single_grid.cu>
#include <bfs_level_grid.cu>

using namespace b40c;
using namespace bfs;


/******************************************************************************
 * Defines, constants, globals 
 ******************************************************************************/

//#define __B40C_ERROR_CHECKING__		 

bool g_verbose;
bool g_verbose2;
bool g_undirected;


/******************************************************************************
 * Housekeeping Routines
 ******************************************************************************/

/**
 * Displays the commandline usage for this tool
 */
void Usage() 
{
	printf("\ntest_bfs <graph type> <graph type args> [--device=<device index>] "
			"[--v] [--instrumented] [--i=<num-iterations>] [--undirected]"
			"[--src=< <source idx> | randomize >] [--queue-size=<queue size>\n"
			"[--mark-parents]\n"
			"\n"
			"graph types and args:\n"
			"\tgrid2d <width>\n"
			"\t\t2D square grid lattice with width <width>.  Interior vertices \n"
			"\t\thave 4 neighbors.  Default source vertex is the grid-center.\n"
			"\tgrid3d <side-length>\n"
			"\t\t3D square grid lattice with width <width>.  Interior vertices \n"
			"\t\thave 6 neighbors.  Default source vertex is the grid-center.\n"
			"\tdimacs [<file>]\n"
			"\t\tReads a DIMACS-formatted graph of directed edges from stdin (or \n"
			"\t\tfrom the optionally-specified file).  Default source vertex is random.\n" 
			"\tmetis [<file>]\n"
			"\t\tReads a METIS-formatted graph of directed edges from stdin (or \n"
			"\t\tfrom the optionally-specified file).  Default source vertex is random.\n" 
			"\tmarket [<file>]\n"
			"\t\tReads a Matrix-Market coordinate-formatted graph of directed edges from stdin (or \n"
			"\t\tfrom the optionally-specified file).  Default source vertex is random.\n"
			"\trandom <n> <m>\n"			
			"\t\tA random graph generator that adds <m> edges to <n> nodes by randomly \n"
			"\t\tchoosing a pair of nodes for each edge.  There are possibilities of \n"
			"\t\tloops and multiple edges between pairs of nodes. Default source vertex \n"
			"\t\tis random.\n"
			"\trr <n> <d>\n"			
			"\t\tA random graph generator that adds <d> randomly-chosen edges to each\n"
			"\t\tof <n> nodes.  There are possibilities of loops and multiple edges\n"
			"\t\tbetween pairs of nodes. Default source vertex is random.\n"
			"\n"
			"--v\tVerbose launch and statistical output is displayed to the console.\n"
			"\n"
			"--v2\tSame as --v, but also displays the input graph to the console.\n"
			"\n"
			"--instrumented\tKernels keep track of queue-passes, redundant work (i.e., the \n"
			"\t\toverhead of duplicates in the frontier), and average barrier wait (a \n"
			"\t\trelative indicator of load imbalance.)\n"
			"\n"
			"--i\tPerforms <num-iterations> test-iterations of BFS traversals.\n"
			"\t\tDefault = 1\n"
			"\n"
			"--src\tBegins BFS from the vertex <source idx>. Default is specific to \n"
			"\t\tgraph-type.  If alternatively specified as \"randomize\", each \n"
			"\t\ttest-iteration will begin with a newly-chosen random source vertex.\n"
			"\n"
			"--queue-size\tAllocates a frontier queue of <queue size> elements.  Default\n"
			"\t\tis the size of the edge list.\n"
			"\n"
			"--mark-parents\tParent vertices are marked instead of source distances, i.e., it\n"
			"\t\tcreates an ancestor tree rooted at the source vertex.\n"
			"\n"
			"--undirected\tEdges are undirected.  Reverse edges are added to DIMACS and\n"
			"\t\trandom graphs, effectively doubling the CSR graph representation size.\n"
			"\t\tGrid2d/grid3d graphs are undirected regardless of this flag, and rr \n"
			"\t\tgraphs are directed regardless of this flag.\n"
			"\n");
}

/**
 * Displays the BFS result (i.e., distance from source)
 */
template<typename VertexId, typename SizeT>
void DisplaySolution(VertexId* source_path, SizeT nodes)
{
	printf("[");
	for (VertexId i = 0; i < nodes; i++) {
		PrintValue(i);
		printf(":");
		PrintValue(source_path[i]);
		printf(", ");
	}
	printf("]\n");
}


/******************************************************************************
 * Performance/Evaluation Statistics
 ******************************************************************************/

struct Statistic 
{
	double mean;
	double m2;
	size_t count;
	
	Statistic() : mean(0.0), m2(0.0), count(0) {}
	
	/**
	 * Updates running statistic, returning bias-corrected sample variance.
	 * Online method as per Knuth.
	 */
	double Update(double sample)
	{
		count++;
		double delta = sample - mean;
		mean = mean + (delta / count);
		m2 = m2 + (delta * (sample - mean));
		return m2 / (count - 1);					// bias-corrected 
	}
	
};

struct Stats {
	char *name;
	Statistic rate;
	Statistic passes;
	Statistic redundant_work;
	Statistic barrier_wait;
	
	Stats() : name(NULL), rate(), passes(), redundant_work(), barrier_wait() {}
	Stats(char *name) : name(name), rate(), passes(), redundant_work(), barrier_wait() {}
};


/**
 * Displays timing and correctness statistics 
 */
template <
	bool MARK_PARENTS,
	typename VertexId,
	typename Value,
	typename SizeT>
void DisplayStats(
	Stats 									&stats,
	VertexId 								src,
	VertexId 								*h_source_path,							// computed answer
	VertexId 								*reference_source_dist,					// reference answer
	const CsrGraph<VertexId, Value, SizeT> 	&csr_graph,	// reference host graph
	double 									elapsed,
	int 									passes,
	SizeT 									total_queued,
	double 									avg_barrier_wait)
{
	// Compute nodes and edges visited
	SizeT edges_visited = 0;
	SizeT nodes_visited = 0;
	for (VertexId i = 0; i < csr_graph.nodes; i++) {
		if (h_source_path[i] > -1) {
			nodes_visited++;
			edges_visited += csr_graph.row_offsets[i + 1] - csr_graph.row_offsets[i];
		}
	}
	
	double redundant_work = 0.0;
	if (total_queued > 0)  {
		redundant_work = ((double) total_queued - edges_visited) / edges_visited;		// measure duplicate edges put through queue
	}
	redundant_work *= 100;

	// Display test name
	printf("[%s] finished. ", stats.name);

	// Display correctness
	if (reference_source_dist != NULL) {
		printf("Validity: ");
		fflush(stdout);
		if (!MARK_PARENTS) {

			// Simply compare with the reference source-distance
			CompareResults(h_source_path, reference_source_dist, csr_graph.nodes, true);

		} else {

			// Verify plausibility of parent markings
			bool correct = true;
			for (VertexId node = 0; node < csr_graph.nodes; node++) {
				VertexId parent = h_source_path[node];

				// Check that parentless nodes have zero or unvisited source distance
				VertexId node_dist = reference_source_dist[node];
				if (parent < 0) {
					if (reference_source_dist[node] > 0) {
						printf("INCORRECT: parentless node %lld (parent %lld) has positive distance distance %lld",
							(long long) node, (long long) parent, (long long) node_dist);
						correct = false;
						break;
					}
					continue;
				}

				// Check that parent has iteration one less than node
				VertexId parent_dist = reference_source_dist[parent];
				if (parent_dist + 1 != node_dist) {
					printf("INCORRECT: parent %lld has distance %lld, node %lld has distance %lld",
						(long long) parent, (long long) parent_dist, (long long) node, (long long) node_dist);
					correct = false;
					break;
				}

				// Check that parent is in fact a parent
				bool found = false;
				for (SizeT neighbor_offset = csr_graph.row_offsets[parent];
					neighbor_offset < csr_graph.row_offsets[parent + 1];
					neighbor_offset++)
				{
					if (csr_graph.column_indices[neighbor_offset] == node) {
						found = true;
						break;
					}
				}
				if (!found) {
					printf("INCORRECT: %lld is not a neighbor of %lld",
						(long long) parent, (long long) node);
					correct = false;
					break;
				}
			}

			if (correct) {
				printf("CORRECT");
			}

		}
	}
	printf("\n");

	// Display statistics
	if (nodes_visited < 5) {
		printf("Fewer than 5 vertices visited.\n");

	} else {
		
		// Display the specific sample statistics
		double m_teps = (double) edges_visited / (elapsed * 1000.0); 
		printf("\telapsed: %.3f ms, rate: %.3f MiEdges/s", elapsed, m_teps);
		if (passes != 0) printf(", passes: %d", passes);
		if (avg_barrier_wait != 0) {
			printf("\n\tavg cta waiting: %.3f ms (%.2f%%), avg g-barrier wait: %.4f ms",
				avg_barrier_wait, avg_barrier_wait / elapsed * 100, avg_barrier_wait / passes);
		}
		printf("\n\tsrc: %lld, nodes visited: %lld, edges visited: %lld",
			(long long) src, (long long) nodes_visited, (long long) edges_visited);
		if (redundant_work > 0) {
			printf(", redundant work: %.2f%%", redundant_work);
		}
		printf("\n");

		// Display the aggregate sample statistics
		printf("\tSummary after %d test iterations (bias-corrected):\n", stats.rate.count + 1); 

		double passes_stddev = sqrt(stats.passes.Update((double) passes));
		if (passes > 0) printf(			"\t\t[Passes]:           u: %.1f, s: %.1f, cv: %.4f\n",
			stats.passes.mean, passes_stddev, passes_stddev / stats.passes.mean);

		double redundant_work_stddev = sqrt(stats.redundant_work.Update(redundant_work));
		if (redundant_work > 0) printf(	"\t\t[redundant work %%]: u: %.2f, s: %.2f, cv: %.4f\n",
			stats.redundant_work.mean, redundant_work_stddev, redundant_work_stddev / stats.redundant_work.mean);

		double barrier_wait_stddev = sqrt(stats.barrier_wait.Update(avg_barrier_wait / elapsed * 100));
		if (avg_barrier_wait > 0) printf(	"\t\t[Waiting %%]:        u: %.2f, s: %.2f, cv: %.4f\n",
			stats.barrier_wait.mean, barrier_wait_stddev, barrier_wait_stddev / stats.barrier_wait.mean);

		double rate_stddev = sqrt(stats.rate.Update(m_teps));
		printf(								"\t\t[Rate MiEdges/s]:   u: %.3f, s: %.3f, cv: %.4f\n", 
			stats.rate.mean, rate_stddev, rate_stddev / stats.rate.mean);
	}
	
	fflush(stdout);

}
		

/******************************************************************************
 * BFS Testing Routines
 ******************************************************************************/

template <
	typename BfsEnactor,
	typename ProblemStorage,
	typename VertexId,
	typename Value,
	typename SizeT>
void TestGpuBfs(
	BfsEnactor 								&enactor,
	ProblemStorage 							&bfs_problem,
	VertexId 								src,
	VertexId 								*h_source_path,						// place to copy results out to
	VertexId 								*reference_source_dist,
	const CsrGraph<VertexId, Value, SizeT> 	&csr_graph,							// reference host graph
	Stats									&stats)								// running statistics
{
	// (Re)initialize distances
	bfs_problem.Reset();

	// Perform BFS
	CpuTimer cpu_timer;
	cpu_timer.Start();
	enactor.EnactSearch(bfs_problem, src);
	cpu_timer.Stop();
	float elapsed = cpu_timer.ElapsedMillis();

	// Copy out results
	cudaMemcpy(
		h_source_path,
		bfs_problem.d_source_path,
		bfs_problem.nodes * sizeof(VertexId),
		cudaMemcpyDeviceToHost);
	
	SizeT 		total_queued = 0;
	int 		passes = 0;
	double		avg_barrier_wait = 0.0;

	enactor.GetStatistics(total_queued, passes, avg_barrier_wait);
	DisplayStats<ProblemStorage::ProblemType::MARK_PARENTS>(
		stats,
		src,
		h_source_path,
		reference_source_dist,
		csr_graph,
		elapsed,
		passes,
		total_queued,
		avg_barrier_wait);
}


/**
 * A simple CPU-based reference BFS ranking implementation.  
 * 
 * Computes the distance of each node from the specified source node. 
 */
template<
	typename VertexId,
	typename Value,
	typename SizeT>
void SimpleReferenceBfs(
	const CsrGraph<VertexId, Value, SizeT> 	&csr_graph,
	VertexId 								*source_path,
	VertexId 								src,
	Stats									&stats)								// running statistics
{
	// (Re)initialize distances
	for (VertexId i = 0; i < csr_graph.nodes; i++) {
		source_path[i] = -1;
	}
	source_path[src] = 0;

	// Initialize queue for managing previously-discovered nodes
	std::deque<VertexId> frontier;
	frontier.push_back(src);

	//
	// Perform BFS 
	//
	
	CpuTimer cpu_timer;
	cpu_timer.Start();
	while (!frontier.empty()) {
		
		// Dequeue node from frontier
		VertexId dequeued_node = frontier.front();
		frontier.pop_front();
		VertexId dist = source_path[dequeued_node];

		// Locate adjacency list
		int edges_begin = csr_graph.row_offsets[dequeued_node];
		int edges_end = csr_graph.row_offsets[dequeued_node + 1];

		for (int edge = edges_begin; edge < edges_end; edge++) {

			// Lookup neighbor and enqueue if undiscovered 
			VertexId neighbor = csr_graph.column_indices[edge];
			if (source_path[neighbor] == -1) {
				source_path[neighbor] = dist + 1;
				frontier.push_back(neighbor);
			}
		}
	}
	cpu_timer.Stop();
	float elapsed = cpu_timer.ElapsedMillis();

	DisplayStats<false, VertexId, Value, SizeT>(
		stats,
		src,
		source_path,
		NULL,						// No reference source path
		csr_graph,
		elapsed,
		0,							// No passes
		0,							// No redundant queuing
		0);							// No barrier wait
}


/**
 * Runs tests
 */
template <
	typename VertexId,
	typename Value,
	typename SizeT,
	bool INSTRUMENT,
	bool MARK_PARENTS>
void RunTests(
	const CsrGraph<VertexId, Value, SizeT> &csr_graph,
	VertexId src,
	bool randomized_src,
	int test_iterations,
	int max_grid_size,
	int queue_size) 
{
	// Allocate host-side source_distance array (for both reference and gpu-computed results)
	VertexId* reference_source_dist 	= (VertexId*) malloc(sizeof(VertexId) * csr_graph.nodes);
	VertexId* h_source_path 			= (VertexId*) malloc(sizeof(VertexId) * csr_graph.nodes);

	// Allocate a BFS enactor (with maximum frontier-queue size the size of the edge-list)
	LevelGridBfsEnactor bfs_sg_enactor(g_verbose);
//	SingleGridBfsEnactor bfs_sg_enactor(g_verbose);

	// Allocate problem on GPU
	BfsCsrProblem<VertexId, SizeT, MARK_PARENTS> bfs_problem;
	if (bfs_problem.FromHostProblem(
		csr_graph.nodes,
		csr_graph.edges,
		csr_graph.column_indices,
		csr_graph.row_offsets))
	{
		exit(1);
	}
	
	// Initialize statistics
	Stats stats[2];
	stats[0] = Stats("Simple CPU BFS");
	stats[1] = Stats("Single-grid, contract-expand GPU BFS");
	
	printf("Running %s %s tests...\n\n",
		(INSTRUMENT) ? "instrumented" : "non-instrumented",
		(MARK_PARENTS) ? "parent-marking" : "distance-marking");
	
	// Perform the specified number of test iterations
	int test_iteration = 0;
	while (test_iteration < test_iterations) {
	
		// If randomized-src was specified, re-roll the src
		if (randomized_src) src = RandomNode(csr_graph.nodes);
		
		printf("---------------------------------------------------------------\n");

		// Compute reference CPU BFS solution for source-distance
		SimpleReferenceBfs(csr_graph, reference_source_dist, src, stats[0]);
		printf("\n");

		// Perform contract-expand GPU BFS search
		TestGpuBfs(
			bfs_sg_enactor,
			bfs_problem,
			src,
			h_source_path,
			reference_source_dist,
			csr_graph,
			stats[1]);
		printf("\n");

		if (g_verbose2) {
			printf("Reference solution: ");
			DisplaySolution(reference_source_dist, csr_graph.nodes);
			printf("Computed solution (%s): ", (MARK_PARENTS) ? "parents" : "source dist");
			DisplaySolution(h_source_path, csr_graph.nodes);
			printf("\n");
		}
		
		if (randomized_src) {
			test_iteration = stats[0].rate.count;
		} else {
			test_iteration++;
		}
	}
	
	
	//
	// Cleanup
	//
	
	if (reference_source_dist) free(reference_source_dist);
	if (h_source_path) free(h_source_path);
	
	cudaThreadSynchronize();
}


/******************************************************************************
 * Main
 ******************************************************************************/

int main( int argc, char** argv)  
{
	typedef int VertexId;						// Use as the node identifier type
	typedef int Value;							// Use as the value type
	typedef int SizeT;							// Use as the graph size type
	
	VertexId 	src 			= -1;			// Use whatever default for the specified graph-type
	char* 		src_str			= NULL;
	bool 		randomized_src	= false;
	bool 		instrumented	= false;
	bool 		mark_parents	= false;
	int 		test_iterations = 1;
	int 		max_grid_size 	= 0;			// Default: leave it up the enactor
	SizeT 		queue_size		= -1;			// Default: the size of the edge list

	CommandLineArgs args(argc, argv);
	DeviceInit(args);
	cudaSetDeviceFlags(cudaDeviceMapHost);

	srand(0);									// Presently deterministic
	//srand(time(NULL));	

	//
	// Check command line arguments
	// 
	
	if (args.CheckCmdLineFlag("help")) {
		Usage();
		return 1;
	}
	instrumented = args.CheckCmdLineFlag("instrumented");
	args.GetCmdLineArgument("src", src_str);
	if (src_str != NULL) {
		if (strcmp(src_str, "randomize") == 0) {
			randomized_src = true;
		} else {
			src = atoi(src_str);
		}
	}
	g_undirected = args.CheckCmdLineFlag("undirected");
	mark_parents = args.CheckCmdLineFlag("mark-parents");
	args.GetCmdLineArgument("i", test_iterations);
	args.GetCmdLineArgument("max-ctas", max_grid_size);
	args.GetCmdLineArgument("queue-size", queue_size);
	if (g_verbose2 = args.CheckCmdLineFlag("v2")) {
		g_verbose = true;
	} else {
		g_verbose = args.CheckCmdLineFlag("v");
	}
	int flags = args.ParsedArgc();
	int graph_args = argc - flags - 1;
	
	
	//
	// Obtain CSR search graph
	//

	CsrGraph<VertexId, Value, SizeT> csr_graph;
	
	if (graph_args < 1) {
		Usage();
		return 1;
	}
	std::string graph_type = argv[1];
	if (graph_type == "grid2d") {
		// Two-dimensional regular lattice grid (degree 4)
		if (graph_args < 2) { Usage(); return 1; }
		VertexId width = atoi(argv[2]);
		if (BuildGrid2dGraph(width, src, csr_graph) != 0) {
			return 1;
		}

	} else if (graph_type == "grid3d") {
		// Three-dimensional regular lattice grid (degree 6)
		if (graph_args < 2) { Usage(); return 1; }
		VertexId width = atoi(argv[2]);
		if (BuildGrid3dGraph(width, src, csr_graph) != 0) {
			return 1;
		}

	} else if (graph_type == "dimacs") {
		// DIMACS-formatted graph file
		if (graph_args < 1) { Usage(); return 1; }
		char *dimacs_filename = (graph_args == 2) ? argv[2] : NULL;
		if (BuildDimacsGraph(dimacs_filename, src, csr_graph, g_undirected) != 0) {
			return 1;
		}
		
	} else if (graph_type == "metis") {
		// METIS-formatted graph file
		if (graph_args < 1) { Usage(); return 1; }
		char *metis_filename = (graph_args == 2) ? argv[2] : NULL;
		if (BuildMetisGraph(metis_filename, src, csr_graph) != 0) {
			return 1;
		}
		
	} else if (graph_type == "market") {
		// Matrix-market coordinate-formatted graph file
		if (graph_args < 1) { Usage(); return 1; }
		char *market_filename = (graph_args == 2) ? argv[2] : NULL;
		if (BuildMarketGraph(market_filename, src, csr_graph) != 0) {
			return 1;
		}

	} else if (graph_type == "random") {
		// Random graph of n nodes and m edges
		if (graph_args < 3) { Usage(); return 1; }
		SizeT nodes = atol(argv[2]);
		SizeT edges = atol(argv[3]);
		if (BuildRandomGraph(nodes, edges, src, csr_graph, g_undirected) != 0) {
			return 1;
		}

	} else if (graph_type == "rr") {
		// Random-regular-ish graph of n nodes, each with degree d (allows loops and cycles)
		if (graph_args < 3) { Usage(); return 1; }
		SizeT nodes = atol(argv[2]);
		int degree = atol(argv[3]);
		if (BuildRandomRegularishGraph(nodes, degree, src, csr_graph) != 0) {
			return 1;
		}

	} else {
		// Unknown graph type
		fprintf(stderr, "Unspecified graph type\n");
		return 1;
	}
	
	// Optionally display graph
	if (g_verbose2) {
		printf("\n");
		csr_graph.DisplayGraph();
		printf("\n");
	}
	csr_graph.PrintHistogram();

	// Run tests
	if (instrumented) {
		// Run instrumented kernel for runtime statistics
		if (mark_parents) {
			RunTests<VertexId, Value, SizeT, true, true>(
				csr_graph, src, randomized_src, test_iterations, max_grid_size, queue_size);
		} else {
			RunTests<VertexId, Value, SizeT, true, false>(
				csr_graph, src, randomized_src, test_iterations, max_grid_size, queue_size);
		}
	} else {
		// Run regular kernel 
		if (mark_parents) {
			RunTests<VertexId, Value, SizeT, false, true>(
				csr_graph, src, randomized_src, test_iterations, max_grid_size, queue_size);
		} else {
			RunTests<VertexId, Value, SizeT, false, false>(
				csr_graph, src, randomized_src, test_iterations, max_grid_size, queue_size);
		}
	}
}
