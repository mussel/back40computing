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
 ******************************************************************************/

/******************************************************************************
 * Scan problem type
 ******************************************************************************/

#pragma once

#include <b40c/reduction/problem_type.cuh>

namespace b40c {
namespace scan {


/**
 * Type of scan problem
 */
template <
	typename T,
	typename SizeT,
	bool _EXCLUSIVE,
	T BinaryOp(const T&, const T&),
	T _Identity()>
struct ProblemType : reduction::ProblemType<T, SizeT, BinaryOp>	// Inherit from reduction problem type
{
	static const bool EXCLUSIVE = _EXCLUSIVE;

	// Wrapper for the identity operator
	static __host__ __device__ __forceinline__ T Identity()
	{
		return _Identity();
	}

};


} // namespace scan
} // namespace b40c
