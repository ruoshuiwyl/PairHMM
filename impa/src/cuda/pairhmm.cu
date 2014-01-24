#include <cstdlib>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <algorithm>
#include <cctype>
#include <fstream>
#include <sstream>
#include "common.h"

typedef unsigned long ul;
typedef unsigned char uc;

#define COMPDIAGS 60
#define COMPBUFFSIZE 30

#define MIN(a,b) (((a)<(b))?(a):(b))
#define PARALLELMXY (BLOCKHEIGHT == 3)
#define TX (threadIdx.x)
#define TY (threadIdx.y)
#define TID (threadIdx.x + BLOCKWIDTH * threadIdx.y)
#define NTH (BLOCKHEIGHT * BLOCKWIDTH)
#define THREADM (threadIdx.y == 0)
#define THREADX (threadIdx.y == 1)
#define THREADY (threadIdx.y == 2)

#define MAX_COMPARISONS_PER_SPLIT ((unsigned long) 35000)
#define MAX_H 5120
#define MAX_R 1536
#define MAX_SIMULTANEOUS_BLOCKS 150

template <int ROWS, int DIAGS, int BUFFSIZE, typename NUMBER>
struct PubVars
{
	ul H, R;
	char h[ROWS+DIAGS-1];
	char r[ROWS];
	char4 qidc[ROWS];
	ul nblockrows, nblockcols;
	Haplotype hap;
	ReadSequence rs;
	char *chunk;

	NUMBER ph2pr[128];
	NUMBER m1[ROWS], m2[ROWS], m3[ROWS];
	NUMBER x1[ROWS], x2[ROWS], x3[ROWS];
	NUMBER y1[ROWS], y2[ROWS], y3[ROWS];
	NUMBER *m, *mp, *mpp;
	NUMBER *x, *xp, *xpp;
	NUMBER *y, *yp, *ypp;
	NUMBER *g_lastM, *g_lastX, *g_lastY;
	NUMBER lastM[DIAGS+1], lastX[DIAGS+1], lastY[DIAGS+1];
	NUMBER buffM[BUFFSIZE], buffX[BUFFSIZE], buffY[BUFFSIZE];
	ul buffsz;
	ul buffstart;
	NUMBER result;
};

template<class T>
__device__ static inline
T INITIAL_CONSTANT();

template<>
__device__ static inline
float INITIAL_CONSTANT<float>()
{
	return 1e32f;
}

template<>
__device__ static inline
double INITIAL_CONSTANT<double>()
{
	return ldexp(1.0, 1020);
}


template<class T>
__device__ static inline
T MIN_ACCEPTED();

template<>
__device__ static inline
float MIN_ACCEPTED<float>()
{
	return 1e-28f;
}

template<>
__device__ static inline
double MIN_ACCEPTED<double>()
{
	return 0.0;
}




template <int ROWS, int DIAGS, int BUFFSIZE, typename NUMBER>
__device__ inline
void flush_buffer
(
	PubVars<ROWS, DIAGS, BUFFSIZE, NUMBER> &pv
)
{
	for (int k = TID; k < pv.buffsz; k += NTH)
	{
		pv.g_lastM[pv.buffstart + k] = pv.buffM[k];
		pv.g_lastX[pv.buffstart + k] = pv.buffX[k];
		pv.g_lastY[pv.buffstart + k] = pv.buffY[k];
	}
}


template <int ROWS, int DIAGS, int BUFFSIZE, typename NUMBER>
__device__ inline
void load_previous_results
(
	int &j, 
	PubVars<ROWS, DIAGS, BUFFSIZE, NUMBER> &pv
)
{
	for (int c = ((j == 0) ? 1 : 0) + TID; c < MIN(pv.H + 1 - j * DIAGS, DIAGS) + 1; c += NTH)
	{
		pv.lastM[c] = pv.g_lastM[j * DIAGS + c - 1];
		pv.lastX[c] = pv.g_lastX[j * DIAGS + c - 1];
		pv.lastY[c] = pv.g_lastY[j * DIAGS + c - 1];
	}
}


template <int ROWS, int DIAGS, int BUFFSIZE, typename NUMBER>
__device__ inline
void load_hap_data
(
	int &j,
	PubVars<ROWS, DIAGS, BUFFSIZE, NUMBER> &pv
)
{
	if (TID < DIAGS)
		for (int c = TID; c < ROWS - 1; c += DIAGS)
			pv.h[c] = pv.h[c + DIAGS];

	__syncthreads();

	for (int c = ((j == 0) ? 1 : 0) + TID; c < MIN(DIAGS, pv.H + 1 - j * DIAGS); c += NTH)
		pv.h[ROWS - 1 + c] = pv.chunk[pv.hap.h + j * DIAGS + c - 1];
}


template <int ROWS, int DIAGS, int BUFFSIZE, typename NUMBER>
__device__ inline 
void load_read_data
(
	int &i, 
	PubVars<ROWS, DIAGS, BUFFSIZE, NUMBER> &pv
)
{
	for (int r = ((i == 0) ? 1 : 0) + TID; r < MIN(ROWS, pv.R + 1 - i * ROWS); r += NTH)
	{
		pv.r[r] = pv.chunk[pv.rs.r + i * ROWS + r - 1];
		pv.qidc[r].x = pv.chunk[pv.rs.qidc + 4 * (i * ROWS + r - 1) + 0];
		pv.qidc[r].y = pv.chunk[pv.rs.qidc + 4 * (i * ROWS + r - 1) + 1];
		pv.qidc[r].z = pv.chunk[pv.rs.qidc + 4 * (i * ROWS + r - 1) + 2];
		pv.qidc[r].w = pv.chunk[pv.rs.qidc + 4 * (i * ROWS + r - 1) + 3];
	}
}

template <int ROWS, int DIAGS, int BUFFSIZE, typename NUMBER>
__device__ inline
void notfirstline_firstcolum
(
	int &r, 
	PubVars<ROWS, DIAGS, BUFFSIZE, NUMBER> &pv, 
	NUMBER &_m, 
	NUMBER &_x
)
{
	if (PARALLELMXY)
	{
		if (THREADM)
			pv.m[r] = (NUMBER(0.0));

		if (THREADX)
			pv.x[r] = _m * pv.ph2pr[pv.qidc[r].y] + _x * pv.ph2pr[pv.qidc[r].w];

		if (THREADY)
			pv.y[r] = (NUMBER(0.0));
	}
	else
	{
		pv.m[r] = (NUMBER(0.0));
		pv.x[r] = _m * pv.ph2pr[pv.qidc[r].y] + _x * pv.ph2pr[pv.qidc[r].w];
		pv.y[r] = (NUMBER(0.0));
	}
}

template <int ROWS, int DIAGS, int BUFFSIZE, typename NUMBER>
__device__ inline 
void notfirstline_notfirstcolumn
(
	int &r, 
	int &i, 
	int &diag, 
	PubVars<ROWS, DIAGS, BUFFSIZE, NUMBER> &pv, 
	NUMBER &M_m, 
	NUMBER &M_x, 
	NUMBER &M_y, 
	NUMBER &X_m, 
	NUMBER &X_x, 
	NUMBER &Y_m, 
	NUMBER &Y_y
)
{
	NUMBER t1, t2, t3, dist;

	if (PARALLELMXY)
	{
		if (THREADM)
		{
			t1 = (NUMBER(1.0)) - pv.ph2pr[(pv.qidc[r].y + pv.qidc[r].z) & 127];
			t2 = (NUMBER(1.0)) - pv.ph2pr[pv.qidc[r].w];
			t3 = pv.ph2pr[pv.qidc[r].x];
			dist = (pv.r[r] == pv.h[ROWS - 1 + diag - r] || pv.r[r] == 'N' || pv.h[ROWS - 1 + diag - r] == 'N') ? (NUMBER(1.0)) - t3 : t3;
			pv.m[r] = dist * (M_m * t1 + M_x * t2 + M_y * t2);
		}

		if (THREADX)
		{
			t1 = pv.ph2pr[pv.qidc[r].y];
			t2 = pv.ph2pr[pv.qidc[r].w];
			pv.x[r] = X_m * t1 + X_x * t2;
		}

		if (THREADY)
		{
			t1 = ((unsigned)r + i*ROWS==pv.R) ? (NUMBER(1.0)) : pv.ph2pr[pv.qidc[r].z];
			t2 = ((unsigned)r + i*ROWS==pv.R) ? (NUMBER(1.0)) : pv.ph2pr[pv.qidc[r].w];
			pv.y[r] = Y_m * t1 + Y_y * t2;
		}
	}
	else
	{
		t1 = (NUMBER(1.0)) - pv.ph2pr[(pv.qidc[r].y + pv.qidc[r].z) & 127];
		t2 = (NUMBER(1.0)) - pv.ph2pr[pv.qidc[r].w];
		t3 = pv.ph2pr[pv.qidc[r].x];
		dist = (pv.r[r] == pv.h[ROWS - 1 + diag - r] || pv.r[r] == 'N' || pv.h[ROWS - 1 + diag - r] == 'N') ? (NUMBER(1.0)) - t3 : t3;
		pv.m[r] = dist * (M_m * t1 + M_x * t2 + M_y * t2);

		t1 = pv.ph2pr[pv.qidc[r].y];
		t2 = pv.ph2pr[pv.qidc[r].w];
		pv.x[r] = X_m * t1 + X_x * t2;

		t1 = ((unsigned)r + i * ROWS == pv.R) ? (NUMBER(1.0)) : pv.ph2pr[pv.qidc[r].z];
		t2 = ((unsigned)r + i * ROWS == pv.R) ? (NUMBER(1.0)) : pv.ph2pr[pv.qidc[r].w];
		pv.y[r] = Y_m * t1 + Y_y * t2;
	}
}

template <int ROWS, int DIAGS, int BUFFSIZE, typename NUMBER>
__device__ inline
void firstline_firstcolum
(
	PubVars<ROWS, DIAGS, BUFFSIZE, NUMBER> &pv
)
{
	if (PARALLELMXY)
	{
		if (THREADM)
			pv.m[0] = (NUMBER(0.0));

		if (THREADX)
			pv.x[0] = (NUMBER(0.0));

		if (THREADY)
			pv.y[0] = INITIAL_CONSTANT<NUMBER>() / pv.H;
	}
	else
	{
		pv.m[0] = (NUMBER(0.0));
		pv.x[0] = (NUMBER(0.0));
		pv.y[0] = INITIAL_CONSTANT<NUMBER>() / pv.H;
	}
}

template <int ROWS, int DIAGS, int BUFFSIZE, typename NUMBER>
__device__ 
inline 
void firstline_notfirstcolum
(
	PubVars<ROWS, DIAGS, BUFFSIZE, NUMBER> &pv
)
{
	if (PARALLELMXY)
	{
		if (THREADM)
			pv.m[0] = (NUMBER(0.0));

		if (THREADX)
			pv.x[0] = (NUMBER(0.0));

		if (THREADY)
			pv.y[0] = INITIAL_CONSTANT<NUMBER>() / pv.H;
	}
	else
	{
		pv.m[0] = (NUMBER(0.0));
		pv.x[0] = (NUMBER(0.0));
		pv.y[0] = INITIAL_CONSTANT<NUMBER>() / pv.H;
	}
}

template <int ROWS, int DIAGS, int BUFFSIZE, typename NUMBER>
__device__ inline
void rotatediags
(
	PubVars<ROWS, DIAGS, BUFFSIZE, NUMBER> &pv
)
{
	NUMBER *sw;
	sw = pv.mpp; pv.mpp = pv.mp; pv.mp = pv.m; pv.m = sw;
	sw = pv.xpp; pv.xpp = pv.xp; pv.xp = pv.x; pv.x = sw;
	sw = pv.ypp; pv.ypp = pv.yp; pv.yp = pv.y; pv.y = sw;
}

template <int ROWS, int DIAGS, int BUFFSIZE, typename NUMBER>
__device__ inline
void block
(
	int &i,
	int &j,
	PubVars<ROWS, DIAGS, BUFFSIZE, NUMBER> &pv
)
{
	if (i > 0)
		load_previous_results(j, pv);

	load_hap_data(j, pv);

	__syncthreads();

	int nRows = MIN(ROWS, (int)(pv.R + 1 - i * ROWS));
	for (int diag = 0; diag < DIAGS; diag++)
	{
		int r, c;
		for (r = TX; r < nRows; r += BLOCKWIDTH)
		{
			c = diag - r + j * DIAGS;
			if (c >= 0 && c <= (int)pv.H)
				if (r == 0)
					if (i == 0)
						if (c == 0)
							firstline_firstcolum(pv);
						else
							firstline_notfirstcolum(pv);
					else
						if (c == 0)
							notfirstline_firstcolum(r, pv, pv.lastM[1], pv.lastX[1]);
						else
							notfirstline_notfirstcolumn(r, i, diag, pv, pv.lastM[diag], pv.lastX[diag], pv.lastY[diag], pv.lastM[diag + 1], pv.lastX[diag + 1], pv.mp[r], pv.yp[r]);
				else
					if (c == 0)
						notfirstline_firstcolum(r, pv, pv.mp[r-1], pv.xp[r-1]);
					else
						notfirstline_notfirstcolumn(r, i, diag, pv, pv.mpp[r-1], pv.xpp[r-1], pv.ypp[r-1], pv.mp[r-1], pv.xp[r-1], pv.mp[r], pv.yp[r]);
		}

		__syncthreads();

		r = nRows - 1;
		c = diag - r + j * DIAGS;
		if ((TID == 0) && (c >= 0) && (c <= (int)pv.H))
		{
			if (i < pv.nblockrows - 1) // buffer!!
			{
				pv.buffM[pv.buffsz] = pv.m[r];
				pv.buffX[pv.buffsz] = pv.x[r];
				pv.buffY[pv.buffsz] = pv.y[r];
				pv.buffsz++;
			}
			else // sum the result!!
			{
				pv.result += (pv.m[r] + pv.x[r]);
			}
		}

		__syncthreads();

		if (pv.buffsz == BUFFSIZE)
		{
			flush_buffer(pv);

			if (TID == 0)
			{
				pv.buffstart += BUFFSIZE;
				pv.buffsz = 0;
			}
			__syncthreads();
		}

		if (TID == 0)
			rotatediags(pv);

		__syncthreads();
	}

	return;
}


template <int ROWS, int DIAGS, int BUFFSIZE, typename NUMBER>
__global__
void compare
(
	Memory mem, 
	NUMBER *g_lastLinesArr, 
	int *g_lastLinesIndex, 
	int *g_compIndex
)
{
	__shared__ PubVars<ROWS, DIAGS, BUFFSIZE, NUMBER> pv;
	__shared__ int compIndex;
	__shared__ bool flag_zero;

	for (int i = TID; i < 128; i += NTH)
		pv.ph2pr[i] = pow((NUMBER(10.0)), -(NUMBER(i)) / (NUMBER(10.0)));

	if (TID == 0)
	{
		int lastLinesIndex = atomicAdd(g_lastLinesIndex, 1);
		pv.g_lastM = g_lastLinesArr + (lastLinesIndex * 3 * MAX_H);
		pv.g_lastX = pv.g_lastM + MAX_H;
		pv.g_lastY = pv.g_lastX + MAX_H;
		pv.chunk = mem.chunk;
	}

	__syncthreads();

	for (;;)
	{
		if (TID == 0)
		{
			compIndex = atomicAdd(g_compIndex, 1);
			flag_zero = (mem.flag[compIndex] == 0);
		}

		__syncthreads();

		if (compIndex >= mem.nres)
			break;

		if (!flag_zero)
			continue;

		if (TID == 0)
		{
			pv.rs = mem.r[mem.cmpR[compIndex]];
			pv.hap = mem.h[mem.cmpH[compIndex]];
			pv.buffsz = 0;
			pv.buffstart = 0;
			pv.H = pv.hap.H;
			pv.R = pv.rs.R;
			pv.nblockrows = (pv.R + ROWS) / ROWS;
			pv.nblockcols = (ROWS + pv.H + DIAGS - 1) / DIAGS;
			pv.m = pv.m1; pv.mp = pv.m2; pv.mpp = pv.m3;
			pv.y = pv.y1; pv.yp = pv.y2; pv.ypp = pv.y3;
			pv.x = pv.x1; pv.xp = pv.x2; pv.xpp = pv.x3;
			pv.result = 0;
		}

		__syncthreads();

		for (int i = 0; i < pv.nblockrows; i++)
		{
			load_read_data(i, pv);

			if (TID == 0)
			{
				pv.buffstart = 0;
				pv.buffsz = 0;
			}

			__syncthreads();

			for (int j = 0; j < pv.nblockcols; j++)
			{
				block(i, j, pv);
				__syncthreads();
			}
			flush_buffer(pv);

			__syncthreads();
		}

		if (TID == 0)
		{
			if (pv.result > MIN_ACCEPTED<NUMBER>())
			{
				mem.flag[compIndex] = 1;
				mem.res[compIndex] = log10(pv.result) - log10(INITIAL_CONSTANT<NUMBER>());
			}
		}

		__syncthreads();
	}

	return;
}

int split
(
	Memory &h_big, 
	Memory &ret
)
{
	static ul lastGroup = 0;
	static ul offset_res = 0;
	ul offset_h = h_big.g[lastGroup].fstH;
	ul offset_r = h_big.g[lastGroup].fstR;
	ul chunk_begin, chunk_end;
	ul j;
	ul fstG = lastGroup;

	if (lastGroup >= h_big.ng)
		return 1;

	ret.nres = 0;
	ret.ng = 0;
	ret.nh = 0;
	ret.nr = 0;
	ret.chunk_sz = 0;

	while ( (lastGroup < h_big.ng) && (ret.nres + h_big.g[lastGroup].nR * h_big.g[lastGroup].nH < MAX_COMPARISONS_PER_SPLIT))
	{
		ret.nres += h_big.g[lastGroup].nR * h_big.g[lastGroup].nH;
		ret.ng++;
		ret.nh += h_big.g[lastGroup].nH;
		ret.nr += h_big.g[lastGroup].nR;
		lastGroup++;
	}

	if (ret.nres == 0)
	{
		fprintf(stderr, "There exists a group with more than MAX_COMPARISONS_PER_SPLIT comparisons\n");
		exit(0);
	}

	chunk_begin = h_big.r[h_big.g[fstG].fstR].r;
	chunk_end = h_big.h[h_big.g[lastGroup-1].fstH + h_big.g[lastGroup-1].nH-1].h + h_big.h[h_big.g[lastGroup-1].fstH + h_big.g[lastGroup-1].nH-1].H + 1;
	ret.chunk_sz = (chunk_end - chunk_begin + 1);
	ret.chunk = h_big.chunk + chunk_begin;

	for (j = 0; j < ret.nh; j++)
	{
		ret.h[j] = h_big.h[offset_h + j];
		ret.h[j].h -= chunk_begin;
	}

	for (j = 0; j < ret.nr; j++)
	{
		ret.r[j] = h_big.r[offset_r + j];
		ret.r[j].r -= chunk_begin;
		ret.r[j].qidc -= chunk_begin;
	}

	for (j = 0; j < ret.nres; j++)
	{
		ret.cmpH[j] = h_big.cmpH[offset_res + j] - offset_h;
		ret.cmpR[j] = h_big.cmpR[offset_res + j] - offset_r;
	}

	offset_res += ret.nres;

	return 0;
}

int main
(
	int argc, 
	char **argv
)
{
	Memory h_big, h_small, d_mem;
	ul already = 0;
	void *g_lastlines;
	int *g_compIndex, compIndex = 0;
	int *g_lastLinesIndex, lastLinesIndex = 0;

	struct
	{
		double start, init_memory, mallocs, comp, output, end, t1, t2;
		float kernel;
	} times;
	times.kernel = 0.f;

	times.start = right_now();
	times.t1 = right_now();
	/*
		init_memory recibe un nombre de archivo y un puntero a una estructura
		Memory, e inicializa h_big (una estructura de tipo Memory) basándose en 
		el contenido del archivo.
	*/
	init_memory(argv[1], &h_big);
	times.t2 = right_now();
	times.init_memory = times.t2 - times.t1;
	times.t1 = right_now();
	h_small.r = (ReadSequence *) malloc(MAX_COMPARISONS_PER_SPLIT * sizeof(ReadSequence));
	h_small.h = (Haplotype *) malloc(MAX_COMPARISONS_PER_SPLIT * sizeof(Haplotype));
	h_small.chunk = (char *) malloc(MAX_COMPARISONS_PER_SPLIT * (MAX_H + MAX_R * 5));
	h_small.cmpH = (ul *) malloc(MAX_COMPARISONS_PER_SPLIT * sizeof(ul));
	h_small.cmpR = (ul *) malloc(MAX_COMPARISONS_PER_SPLIT * sizeof(ul));
	h_small.res = (BIGGEST_NUMBER_REPRESENTATION *) malloc(MAX_COMPARISONS_PER_SPLIT * sizeof(BIGGEST_NUMBER_REPRESENTATION));
	h_small.flag = (char *) malloc(MAX_COMPARISONS_PER_SPLIT);
	h_small.g = NULL;

	g_lastlines = NULL;
	g_compIndex = NULL;
	g_lastLinesIndex = NULL;
	d_mem.r = NULL;
	d_mem.h = NULL;
	d_mem.chunk = NULL;
	d_mem.cmpH = NULL;
	d_mem.cmpR = NULL;
	d_mem.res = NULL;

	cudaMalloc(&g_compIndex, sizeof(int));
	cudaMalloc(&g_lastLinesIndex, sizeof(int));
	cudaMalloc(&g_lastlines, 3 * sizeof(BIGGEST_NUMBER_REPRESENTATION) * MAX_H * MAX_SIMULTANEOUS_BLOCKS);

	cudaMalloc(&(d_mem.r), MAX_COMPARISONS_PER_SPLIT * sizeof(ReadSequence));
	cudaMalloc(&(d_mem.h), MAX_COMPARISONS_PER_SPLIT * sizeof(Haplotype));
	cudaMalloc(&(d_mem.chunk), MAX_COMPARISONS_PER_SPLIT * (MAX_H + MAX_R * 5));
	cudaMalloc(&(d_mem.cmpH), MAX_COMPARISONS_PER_SPLIT * sizeof(ul));
	cudaMalloc(&(d_mem.cmpR), MAX_COMPARISONS_PER_SPLIT * sizeof(ul));
	cudaMalloc(&(d_mem.flag), MAX_COMPARISONS_PER_SPLIT);
	cudaMalloc(&(d_mem.res), MAX_COMPARISONS_PER_SPLIT * sizeof(BIGGEST_NUMBER_REPRESENTATION));
	d_mem.g = NULL;

	if (!g_lastLinesIndex || !g_lastlines || !g_compIndex || !d_mem.r || !d_mem.h || !d_mem.chunk || !d_mem.cmpH || !d_mem.cmpR || !d_mem.res)
	{
		fprintf(stderr, "Some malloc went wrong...\n");
		exit(0);
	}

	times.t2 = right_now();
	times.mallocs = times.t2 - times.t1;

	times.t1 = right_now();
	while (!split(h_big, h_small))
	{
		cudaEvent_t kernel_start, kernel_stop;
		float k_time;
		cudaEventCreate(&kernel_start);
		cudaEventCreate(&kernel_stop);

		d_mem.ng = h_small.ng;
		d_mem.nh = h_small.nh;
		d_mem.nr = h_small.nr;
		d_mem.chunk_sz = h_small.chunk_sz;
		d_mem.nres = h_small.nres;
		cudaMemcpy(d_mem.r, h_small.r, h_small.nr * sizeof(ReadSequence), cudaMemcpyHostToDevice);
		cudaMemcpy(d_mem.h, h_small.h, h_small.nh * sizeof(Haplotype), cudaMemcpyHostToDevice);
		cudaMemcpy(d_mem.chunk, h_small.chunk, h_small.chunk_sz, cudaMemcpyHostToDevice);
		cudaMemcpy(d_mem.cmpH, h_small.cmpH, h_small.nres * sizeof(ul), cudaMemcpyHostToDevice);
		cudaMemcpy(d_mem.cmpR, h_small.cmpR, h_small.nres * sizeof(ul), cudaMemcpyHostToDevice);

		memset(h_small.flag, 0, MAX_COMPARISONS_PER_SPLIT);
		cudaMemcpy(d_mem.flag, h_small.flag, MAX_COMPARISONS_PER_SPLIT, cudaMemcpyHostToDevice);

		dim3 gridDim(MAX_SIMULTANEOUS_BLOCKS);
		dim3 blockDim(BLOCKWIDTH, BLOCKHEIGHT);
		cudaEventRecord(kernel_start, 0);

		cudaMemcpy(g_compIndex, &compIndex, sizeof(int), cudaMemcpyHostToDevice);
		cudaMemcpy(g_lastLinesIndex, &lastLinesIndex, sizeof(int), cudaMemcpyHostToDevice);
		compare<BLOCKWIDTH, COMPDIAGS, COMPBUFFSIZE, float><<<gridDim, blockDim>>>(d_mem, (float *) g_lastlines, g_lastLinesIndex, g_compIndex);

		cudaMemcpy(g_compIndex, &compIndex, sizeof(int), cudaMemcpyHostToDevice);
		cudaMemcpy(g_lastLinesIndex, &lastLinesIndex, sizeof(int), cudaMemcpyHostToDevice);
		compare<BLOCKWIDTH, COMPDIAGS, COMPBUFFSIZE, double><<<gridDim, blockDim>>>(d_mem, (double *) g_lastlines, g_lastLinesIndex, g_compIndex);

		cudaEventRecord(kernel_stop, 0);
		cudaEventSynchronize(kernel_stop);

		cudaMemcpy(h_big.res + already, d_mem.res, d_mem.nres * sizeof(BIGGEST_NUMBER_REPRESENTATION), cudaMemcpyDeviceToHost);
		already += d_mem.nres;
		cudaEventElapsedTime(&k_time, kernel_start, kernel_stop);
		times.kernel += k_time;
	}
	times.t2 = right_now();
	times.comp = times.t2 - times.t1;

	cudaFree(g_lastlines);
	cudaFree(g_lastLinesIndex);
	cudaFree(g_compIndex);
	cudaFree(d_mem.r);
	cudaFree(d_mem.h);
	cudaFree(d_mem.chunk);
	cudaFree(d_mem.cmpH);
	cudaFree(d_mem.cmpR);
	cudaFree(d_mem.res);

	times.t1 = right_now();
	output(h_big.res, h_big.nres, argv[2]);
	times.t2 = right_now();
	times.output = times.t2 - times.t1;
	times.end = right_now();

	printf("INIT_MEMORY: %g\n", times.init_memory * 1000.0);
	printf("MALLOCS: %g\n", times.mallocs * 1000.0);
	printf("COMPUTATION: %g\n", times.comp * 1000.0);
	printf("KERNEL: %f\n", times.kernel);
	printf("OUTPUT: %g\n", times.output * 1000.0);
	printf("TOTAL (measured inside program): %g\n", (times.end - times.start) * 1000.0);

	return 0;
}
