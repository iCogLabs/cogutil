#include "DestinKernel.h"

// C/C++ headers
#include <stdio.h>
#include <stdlib.h>
#include <iostream>
#include <sstream>

// Cuda header
#include <cuda.h>
#include <curand.h>

const int AmountThreads = 128;

using namespace std;

__global__ void CalculateDistance( int States, int InputDimensionlity, float *InputData, float *CentroidVectorData, float *CentroidDist, float *CentroidStarvation );
__global__ void CalculateWinningCentroids( int States, float *CentroidDist, int *WinningCentroids );
__global__ void UpdateStarvation( int States, float StarvationCoefficient, int *WinningCentroids, float *CentroidStarvation );
__global__ void UpdateWinningCentroids( int States, int InputDimensionlity, float LearningRate, float *InputData, float *CentroidVectorData, int *WinningCentroids );
__global__ void CalculateOutput( int States, float *CentroidDist, float *Output );

DestinKernel::DestinKernel( void )
{
    mID=0;
	mRows=0;
	mCols=0;
	mStates=0;
	mInputDimensionlity=0;
    mLearningRate = 0;
    mSTARVATION_COEFFICIENT = 0;
	cuDeviceGetCount(&mDevices);
	cout << "Kernel created" << endl;
}

DestinKernel::~DestinKernel( void )
{
    free ( mCentroidsVectorData );
    cudaFree( dCentroidsVectorData );
    free ( mCentroidsDistance );
    cudaFree( dCentroidsDistance );
    free ( mCentroidStarvation );
    cudaFree( dCentroidStarvation );
    free ( mWinningCentroids );
    cudaFree( dWinningCentroids );
    free ( mNodeOutput );
    cudaFree( dNodeOutput );
    free(mCentroidWinCounter);
    cout << "Kernel destroyed" << endl;
}

void DestinKernel::Create( int ID, int Rows, int Cols, int States, int InputDimensionlity, float FixedLeaningRate, curandGenerator_t gen)
{
    mID = ID;
    mRows = Rows;
    mCols = Cols;
    mStates = States;
    mInputDimensionlity = InputDimensionlity;
    mLearningRate = FixedLeaningRate;

    mSTARVATION_COEFFICIENT = 1.0/((float)InputDimensionlity*(float)InputDimensionlity);
    if ( mSTARVATION_COEFFICIENT < 1.0/512.0 )
    {
        mSTARVATION_COEFFICIENT=1.0/512.0;
    }

    // Define the data sizes
    // Size of de nodes is rows times columns
    sizeOfNodes = mRows*mCols;
    // Size of the data of nodes is rows times columns times centroids
    sizeOfNodeData = sizeOfNodes*mStates;
    // Size of the layer with all vectors is rows times columns times centroids times input vector
    sizeOfLayerData = sizeOfNodeData*mInputDimensionlity;
    // Keep track which centroid one
    mCentroidWinCounter = new int[sizeOfNodeData];
    for(int c=0;c<sizeOfNodeData;c++)
    {
        mCentroidWinCounter[c] = 0;
    }

    // Array full with all the winning centroids of each node
    mWinningCentroids = new int[sizeOfNodes];
    cudaMalloc( (void**)&dWinningCentroids, sizeOfNodes*sizeof(int) );

    // Node data contain the distance to the observation of all centroids (It's is empty the first run)
    mCentroidsDistance = new float[sizeOfNodeData];
    cudaMalloc( (void**)&dCentroidsDistance, sizeOfNodeData*sizeof(float) );

    // Starvation data for all centroids
    mCentroidStarvation = new float[sizeOfNodeData];
    cudaMalloc( (void**)&dCentroidStarvation, sizeOfNodeData*sizeof(float) );
    for(int i=0;i<sizeOfNodeData;i++)
    {
        mCentroidStarvation[i]=1.0f;
    }
    // Copy the data from host to device
    cudaMemcpy(dCentroidStarvation, mCentroidStarvation, sizeOfNodeData*sizeof(float), cudaMemcpyHostToDevice);

    // Output for next layer
    mNodeOutput = new float[sizeOfNodeData];
    cudaMalloc( (void**)&dNodeOutput, sizeOfNodeData*sizeof(float) );

    // The layer data is the one that hold all vectors for all centroids inside each layer
    mCentroidsVectorData = new float[sizeOfLayerData];
    cudaMalloc( (void**)&dCentroidsVectorData, sizeOfLayerData*sizeof(float) );
    // This is to fill the dLayerData with all random numbers between 0.0 and 1.0
    curandGenerateUniform( gen, dCentroidsVectorData, sizeOfLayerData );
}

void DestinKernel::DoDestin( float *Input, stringstream& xml )
{
    // Threads is the amount of thread inside each. block
    dim3 threads( AmountThreads );
    // Grid is the amount of blocks inside a grid.
    dim3 grid( mCols, mRows );
    // Cause of the use of dynamic shared memory you have to tell the kernel how much shared memory space you need for each block.
    int sharedMem = 0;
    // The launch of the kernels itself with centroids(states), dimension, input data and the Data of the layer itself
    sharedMem = (mInputDimensionlity+mInputDimensionlity)*sizeof(float);
    CalculateDistance<<<grid, threads, sharedMem>>>( mStates, mInputDimensionlity, Input, dCentroidsVectorData, dCentroidsDistance, dCentroidStarvation );

    sharedMem = (mStates+mStates)*sizeof(float);
    CalculateWinningCentroids<<<grid, threads, sharedMem>>>( mStates, dCentroidsDistance, dWinningCentroids );

    UpdateStarvation<<<grid, threads>>>( mStates, mSTARVATION_COEFFICIENT, dWinningCentroids, dCentroidStarvation );

    UpdateWinningCentroids<<<grid, threads>>>( mStates, mInputDimensionlity, mLearningRate, Input, dCentroidsVectorData, dWinningCentroids );

    sharedMem = (mStates+mStates)*sizeof(float);
    CalculateOutput<<<grid, threads, sharedMem>>>( mStates, dCentroidsDistance, dNodeOutput );

    this->WriteData(xml);
}

void DestinKernel::WriteData(stringstream& xml)
{
    cudaMemcpy(mCentroidsDistance, dCentroidsDistance, sizeOfNodeData*sizeof(float), cudaMemcpyDeviceToHost);
    cudaMemcpy(mCentroidStarvation, dCentroidStarvation, sizeOfNodeData*sizeof(float), cudaMemcpyDeviceToHost);
    cudaMemcpy(mNodeOutput, dNodeOutput, sizeOfNodeData*sizeof(float), cudaMemcpyDeviceToHost);
    cudaMemcpy(mWinningCentroids, dWinningCentroids, sizeOfNodes*sizeof(int), cudaMemcpyDeviceToHost);

    xml << "<layer id=\"" << mID << "\">" << endl;
    for(int r=0;r<mRows;r++)
    {
        for(int c=0;c<mCols;c++)
        {
            int winningCentroid = mWinningCentroids[r*mCols+c];
            mCentroidWinCounter[(c+r*mCols)*mStates+winningCentroid] += 1;
            xml << "<node id=\"" << r*mCols+c << "\">" << endl;
            xml << "<winningCentroid>" << mWinningCentroids[r*mCols+c] << "</winningCentroid>" << endl;
            for(int s=0;s<mStates;s++)
            {
                xml << "<centroid id=\"" << s << "\" ";
                xml << "lastDistance=\"" << mCentroidsDistance[(c+r*mCols)*mStates+s] << "\" ";
                xml << "starvation=\"" << mCentroidStarvation[(c+r*mCols)*mStates+s] << "\" ";
                xml << "outPut=\"" << mNodeOutput[(c+r*mCols)*mStates+s]  << "\" ";
                xml << "winCount=\"" << mCentroidWinCounter[(c+r*mCols)*mStates+s]  << "\"";
                xml << "/>" << endl;
            }
            xml << "</node>" << endl;
        }
    }
    xml << "</layer>" << endl;
}
// ***********************
// DeSTIN inside CUDA Part
// ***********************
__global__ void CalculateDistance( int States, int InputDimensionlity, float *InputData, float *CentroidVectorData, float *CentroidDist, float *CentroidStarvation)
{
    // This is how to declare a shared memory inside CUDA.
    extern __shared__ float shared[];
    float* input = (float*)&shared;
    float* distance = (float*)&input[InputDimensionlity];

    // We use many threads they need to know where they have to do there work.
    // tid (Thread ID) is the amount of threads inside a block its a fixed amount it can be changed by changing: AmountThreads.
    // Keep in mind that CUDA threads should be in steps of 32 (each warp takes 4 clock cycles where each cycle calculate 8 threads)
    int tid = threadIdx.x;
    // bid (Block ID) this keeps track in witch node we are working you can ask the grid the size of the blocks used in x or y and on a Fermi or higher even z
    int bid = blockIdx.x + blockIdx.y * gridDim.x;

    // make sure the input data is inside shared memory this we are going to compare the amount of centroids.
    while(tid < InputDimensionlity)
    {
        // Put input data for node inside shared memory
        input[tid] = InputData[tid + bid * InputDimensionlity];
        // A trick for when the dimension is bigger then the amount of threads
        tid += blockDim.x;
    }
    // all threads have to be here to be sure shared memory is filled with the input.
    __syncthreads();

    // calculation distance in massive thread style.
    // keep track of the centroid
    int centroid = 0;
    while (centroid<States)
    {
        // reset the tid
        tid = threadIdx.x;
        while(tid < InputDimensionlity)
        {
            // This temp will have for a short while the calculation of input - centroid for position tid (one cell of the vector)
            float temp = 0.0f;
            // distance to input = (input - centroid)*(input - centroid)
            // Small formula to get to the right working position: dimension*centroids*block+current centroid*dimension+thread
            temp = input[tid] - CentroidVectorData[InputDimensionlity*States*bid+centroid*InputDimensionlity+tid];
            distance[tid] = temp * temp;
            // A trick for when the dimension is bigger then the amount of threads
            tid += blockDim.x;
        }
        // all threads have to wait here so we know all distance have been calculated
        __syncthreads();

        // Cause DeSTIN don't work with numbers that are 2^? we have to check for odd numbers
        int dOld = InputDimensionlity;
        // bite wise divide by 2 (should be faster the /2)
        int d = InputDimensionlity >> 1;
        // a sum reduction, This is a common trick on CUDA to add shared memory instead of striding true memory
        // You have to use half the memory each step and each thread will add itself to with the other half.
        while (d != 0)
        {
            // reset the tid
            tid = threadIdx.x;
            dOld = dOld - d*2;
            while(tid < d)
            {
                // the adding calculation
                distance[tid] += distance[tid + d];

                // special case in case of odd number (As long as this don't happen to often it won't effect speed)
                if (dOld == 1 && tid == d-1)
                {
                    distance[tid] += distance[tid + d + 1];
                }
                tid += blockDim.x;
            }
            // Sync moment before starting with next iteration of reduction.
            __syncthreads();

            dOld = d;
            d >>= 1;
        }

        // Write distance to Node Data
        tid = threadIdx.x;
        if(tid == 0)
        {
            // square root on sum of the (input - centroid)*(input - centroid)
            // (Remember that you should copy the data from the device to the host and store it then)
            CentroidDist[centroid+bid*States] = (sqrt(distance[tid]))*CentroidStarvation[centroid+bid*States];
        }
        // go to next centroid inside the node (bid is taking care of the other node)
        centroid++;
    }
}

// To reduce the amount of work that one kernel is doing i have decided that splitting the work over more kernels should speed up the whole procces
__global__ void CalculateWinningCentroids( int States, float *CentroidDist, int *WinningCentroids )
{
    extern __shared__ float shared[];
    float* winner = (float*)&shared;
    float* winnerId = (float*)&winner[States];
    int tid = threadIdx.x;
    int bid = blockIdx.x + blockIdx.y * gridDim.x;

    while(tid < States)
    {
        winnerId[tid] = tid;
        winner[tid] = CentroidDist[tid+bid*States];
        tid += blockDim.x;
    }
    __syncthreads();

    int dOld = States;
    int d = States >> 1;
    while (d != 0)
    {
        tid = threadIdx.x;
        dOld = dOld - d*2;
        while(tid < d)
        {
            if(winner[tid] > winner[tid + d])
            {
                // Move winning centroid to the beginning
                winner[tid] = winner[tid + d];
                winnerId[tid] = winnerId[tid + d];
            }

            if (dOld == 1 && tid == d-1)
            {
                // special case of odd numbers
                if(winner[tid] > winner[tid + d + 1])
                {
                    winner[tid] = winner[tid + d + 1];
                    winnerId[tid] = winnerId[tid + d + 1];
                }
            }
            tid += blockDim.x;
        }
        // Sync moment before starting with next iteration of reduction.
        __syncthreads();

        dOld = d;
        d >>= 1;
    }
    // Write the winning centroid into there position
    tid = threadIdx.x;
    if(tid == 0)
    {
        WinningCentroids[bid] = winnerId[tid];
    }
}

// This is the updating starvation fast and quick to update all the nodes and reset the winning centroid
// According to DeSTIN paper: The winning centroid starvation gets reset while the others starve more
// Aldo this is the simple version of it it might be changed in the further cause this make the network also forget what it learn
// when it is looking at something else for a very long time (Short and Long term memory)
__global__ void UpdateStarvation( int States, float StarvationCoefficient, int *WinningCentroids, float *CentroidStarvation )
{
    // for tid and bid see CalculateDistance kernel.
    int tid = threadIdx.x;
    int bid = blockIdx.x + blockIdx.y * gridDim.x;
    while(tid < States)
    {
        // Let all centroid starve
        CentroidStarvation[tid+bid*States] = (1.0f-StarvationCoefficient)*CentroidStarvation[tid+bid*States];
        // Reset winning centroid
        CentroidStarvation[WinningCentroids[bid]+bid*States] = 1.0f;
        tid += blockDim.x;
    }
}

// Move the winning centroids closer to the observation
__global__ void UpdateWinningCentroids( int States, int InputDimensionlity, float LearningRate, float *InputData, float *CentroidVectorData, int *WinningCentroids )
{
    int tid = threadIdx.x;
    int bid = blockIdx.x + blockIdx.y * gridDim.x;

    int centroid = WinningCentroids[bid];
    float temp;
    int pos;
    while(tid < InputDimensionlity)
    {
        pos = InputDimensionlity*States*bid+centroid*InputDimensionlity+tid;
        temp = CentroidVectorData[pos];
        CentroidVectorData[pos] = temp-(temp -InputData[tid])*LearningRate;

        tid += blockDim.x;
        pos += blockDim.x;
    }
}

__global__ void CalculateOutput( int States, float *CentroidDist, float *Output )
{
    extern __shared__ float shared[];
    float* distance = (float*)&shared;
    float* tPOS = (float*)&distance[States];
    int tid = threadIdx.x;
    int bid = blockIdx.x + blockIdx.y * gridDim.x;

    while(tid < States)
    {
        distance[tid] = CentroidDist[bid*States+tid];
        tPOS[tid] = (float)(1.0/(1e-9+(double)distance[tid]));
        tid += blockDim.x;
    }
    __syncthreads();

    int dOld = States;
    int d = States >> 1;
    while (d != 0)
    {
        tid = threadIdx.x;
        dOld = dOld - d*2;
        while(tid < d)
        {
            tPOS[tid] += tPOS[tid + d];
            if (dOld == 1 && tid == d-1)
            {
                // special case of odd numbers
                tPOS[tid] += tPOS[tid + d + 1];
            }
            tid += blockDim.x;
        }
        // Sync moment before starting with next iteration of reduction.
        __syncthreads();

        dOld = d;
        d >>= 1;
    }

    tid = threadIdx.x;
    while(tid < States)
    {
        // This is the POS for all centroids (It looks like this is the input for the next layer also)
        // The output is missing the advice of higher layer
        Output[tid+bid*States] = (float)(1.0/(1e-9+(double)distance[tid]))/tPOS[0];
        tid += blockDim.x;
    }
}
