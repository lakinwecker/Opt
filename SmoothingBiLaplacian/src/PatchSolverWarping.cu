#include <iostream>

#include "WarpingSolverParameters.h"
#include "PatchSolverWarpingState.h"
#include "PatchSolverWarpingUtil.h"
#include "PatchSolverWarpingEquations.h"

// For the naming scheme of the variables see:
// http://en.wikipedia.org/wiki/Conjugate_gradient_method
// This code is an implementation of their PCG pseudo code

/////////////////////////////////////////////////////////////////////////
// PCG Patch Iteration
/////////////////////////////////////////////////////////////////////////

__global__ void PCGStepPatch_Kernel(PatchSolverInput input, PatchSolverState state, PatchSolverParameters parameters, int ox, int oy)
{
	const unsigned int W = input.width;
	const unsigned int H = input.height;

	const int tId_j = threadIdx.x; // local col idx
	const int tId_i = threadIdx.y; // local row idx

	const int gId_j = blockIdx.x * blockDim.x + threadIdx.x - ox; // global col idx
	const int gId_i = blockIdx.y * blockDim.y + threadIdx.y - oy; // global row idx
	
	//////////////////////////////////////////////////////////////////////////////////////////
	// CACHE data to shared memory
	//////////////////////////////////////////////////////////////////////////////////////////
	
	__shared__ float4 X[SHARED_MEM_SIZE_PATCH]; loadPatchToCache(X, state.d_x, tId_i, tId_j, gId_i, gId_j, W, H, blockIdx.x, blockIdx.y, ox, oy);
	__shared__ float4 T[SHARED_MEM_SIZE_PATCH]; loadPatchToCache(T, state.d_target, tId_i, tId_j, gId_i, gId_j, W, H, blockIdx.x, blockIdx.y, ox, oy);

	__shared__ float4 P [SHARED_MEM_SIZE_PATCH]; setPatchToZero(P,  tId_i, tId_j);

	__shared__ float patchBucket[SHARED_MEM_SIZE_VARIABLES];

	__syncthreads();

	//////////////////////////////////////////////////////////////////////////////////////////
	// CACHE data to registers
	//////////////////////////////////////////////////////////////////////////////////////////

	register float4 X_CC  = readValueFromCache2D(X, tId_i, tId_j);
	register bool isValidPixel = isValid(X_CC);
	
	register float4 Delta = make_float4(0.0f, 0.0f, 0.0f, 0.0f);
	register float4 R;
	register float4 Z;
	register float4 Pre;
	register float  RDotZOld;
	register float4 AP;
	
	__syncthreads();
	
	//////////////////////////////////////////////////////////////////////////////////////////
	// Initialize linear patch systems
	//////////////////////////////////////////////////////////////////////////////////////////
	
	float d = 0.0f;
	if (isValidPixel)
	{
		R = evalMinusJTFDevice(tId_i, tId_j, gId_i, gId_j, W, H, T, X, parameters, Pre); // residuum = J^T x -F - A x delta_0  => J^T x -F, since A x x_0 == 0 
		float4 preRes  = Pre *R;														 // apply preconditioner M^-1
		P [getLinearThreadIdCache(tId_i, tId_j)] = preRes;								 // save for later
	
		d = dot(R, preRes);
	}
	
	patchBucket[getLinearThreadId(tId_i, tId_j)] =  d;										 // x-th term of nomimator for computing alpha and denominator for computing beta
	
	__syncthreads();
	blockReduce(patchBucket, getLinearThreadId(tId_i, tId_j), SHARED_MEM_SIZE_VARIABLES);
	__syncthreads();
	
	if (isValidPixel) RDotZOld = patchBucket[0];							   // read result for later on
	
	__syncthreads();
	
	//////////////////////////////////////////////////////////////////////////////////////////
	// Do patch PCG iterations
	//////////////////////////////////////////////////////////////////////////////////////////
	
	for(unsigned int patchIter = 0; patchIter < parameters.nPatchIterations; patchIter++)
	{
		const float4 currentP  = P [getLinearThreadIdCache(tId_i, tId_j)];
		
		float d = 0.0f;
		if (isValidPixel)
		{
			AP = applyJTJDevice(tId_i, tId_j, gId_i, gId_j, W, H, T, P, X, parameters);	// A x p_k  => J^T x J x p_k 
			d = dot(currentP, AP);														// x-th term of denominator of alpha
		}
	
		patchBucket[getLinearThreadId(tId_i, tId_j)] = d;
		
		__syncthreads();
		blockReduce(patchBucket, getLinearThreadId(tId_i, tId_j), SHARED_MEM_SIZE_VARIABLES);
		__syncthreads();
		
		const float dotProduct = patchBucket[0];
		
		float b = 0.0f;
		if (isValidPixel)
		{
			float alpha = 0.0f;
			if(dotProduct > FLOAT_EPSILON) alpha = RDotZOld/dotProduct;	    // update step size alpha
			Delta  = Delta  + alpha*currentP;								// do a decent step		
			R  = R  - alpha*AP;												// update residuum	
			Z  = Pre *R;													// apply preconditioner M^-1
			b = dot(Z,R);													// compute x-th term of the nominator of beta
		}
		
		__syncthreads();													// Only write if every thread in the block has has read bucket[0]
		
		patchBucket[getLinearThreadId(tId_i, tId_j)] = b;
		
		__syncthreads();
		blockReduce(patchBucket, getLinearThreadId(tId_i, tId_j), SHARED_MEM_SIZE_VARIABLES);	// sum over x-th terms to compute nominator of beta inside this block
		__syncthreads();
		
		if (isValidPixel)
		{
			const float rDotzNew = patchBucket[0];												// get new nominator
			
			float beta = 0.0f;														 
			if(RDotZOld > FLOAT_EPSILON) beta = rDotzNew/RDotZOld;								// update step size beta
			RDotZOld = rDotzNew;																// save new rDotz for next iteration
			P [getLinearThreadIdCache(tId_i, tId_j)] = Z + beta*currentP;						// update decent direction
		}
		
		__syncthreads();
	}
	
	//////////////////////////////////////////////////////////////////////////////////////////
	// Save to global memory
	//////////////////////////////////////////////////////////////////////////////////////////
	
	if (isValidPixel)
	{
		state.d_x[get1DIdx(gId_i, gId_j, W, H)] = X_CC  + Delta;
	}
}

void PCGIterationPatch(PatchSolverInput& input, PatchSolverState& state, PatchSolverParameters& parameters, int ox, int oy)
{
	dim3 blockSize(PATCH_SIZE, PATCH_SIZE);
	dim3 gridSize((input.width + blockSize.x - 1) / blockSize.x + 1, (input.height + blockSize.y - 1) / blockSize.y + 1); // one more for block shift!
	PCGStepPatch_Kernel<<<gridSize, blockSize>>>(input, state, parameters, ox, oy);
	#ifdef _DEBUG
		cutilSafeCall(cudaDeviceSynchronize());
		cutilCheckMsg(__FUNCTION__);
	#endif
}

////////////////////////////////////////////////////////////////////
// Main GN Solver Loop
////////////////////////////////////////////////////////////////////

int offsetX[8] = {(int)(0.0f*PATCH_SIZE), (int)((1.0f/2.0f)*PATCH_SIZE), (int)((1.0f/4.0f)*PATCH_SIZE), (int)((3.0f/4.0f)*PATCH_SIZE), (int)((1.0f/8.0f)*PATCH_SIZE), (int)((5.0f/8.0f)*PATCH_SIZE), (int)((3.0f/8.0f)*PATCH_SIZE), (int)((7.0f/8.0f)*PATCH_SIZE)}; // Halton sequence base 2
int offsetY[8] = {(int)(0.0f*PATCH_SIZE), (int)((1.0f/3.0f)*PATCH_SIZE), (int)((2.0f/3.0f)*PATCH_SIZE), (int)((1.0f/9.0f)*PATCH_SIZE), (int)((4.0f/9.0f)*PATCH_SIZE), (int)((7.0f/9.0f)*PATCH_SIZE), (int)((2.0f/9.0f)*PATCH_SIZE), (int)((5.0f/9.0f)*PATCH_SIZE)}; // Halton sequence base 3

extern "C" void patchSolveStereoStub(PatchSolverInput& input, PatchSolverState& state, PatchSolverParameters& parameters)
{
	int o = 0;
	for(unsigned int nIter = 0; nIter < parameters.nNonLinearIterations; nIter++)
	{	
		PCGIterationPatch(input, state, parameters, offsetX[o], offsetY[o]);
		o = (o+1)%8;
	}
}
