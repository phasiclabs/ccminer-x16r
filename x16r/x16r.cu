// Ravencoin X16R hybrid CPU/CUDA Implementation, penfold 2017

extern "C"
{
#include "sph/sph_blake.h"
#include "sph/sph_bmw.h"
#include "sph/sph_groestl.h"
#include "sph/sph_jh.h"
#include "sph/sph_keccak.h"
#include "sph/sph_skein.h"
#include "sph/sph_luffa.h"
#include "sph/sph_cubehash.h"
#include "sph/sph_shavite.h"
#include "sph/sph_simd.h"
#include "sph/sph_echo.h"
#include "sph/sph_hamsi.h"
#include "sph/sph_fugue.h"
#include "sph/sph_shabal.h"
#include "sph/sph_whirlpool.h"
#include "sph/sph_sha2.h"
}

#include "miner.h"
#include "cuda_helper.h"
#include "cuda_x16r.h"

#include <stdio.h>
#include <unistd.h>
#include <memory.h>

#define X16R_BLAKE      0
#define X16R_BMW        1
#define X16R_GROESTL    2
#define X16R_JH         3
#define X16R_KECCAK     4
#define X16R_SKEIN      5
#define X16R_LUFFA      6
#define X16R_CUBEHASH   7
#define X16R_SHAVITE    8
#define X16R_SIMD       9
#define X16R_ECHO       10
#define X16R_HAMSI      11
#define X16R_FUGUE      12
#define X16R_SHABAL     13
#define X16R_WHIRLPOOL  14
#define X16R_SHA512     15

#define X16R_HASH_COUNT (X16R_SHA512 + 1)

static const char *hash_names[X16R_HASH_COUNT] =
{
    "blake",
    "bmw",
    "groestl",
    "jh",
    "keccak",
    "skein",
    "luffa",
    "cubehash",
    "shavite",
    "simd",
    "echo",
    "hamsi",
    "fugue",
    "shabal",
    "whirlpool",
    "sha512",
};

static const bool run_parallel_fallback_jobs = true;

typedef struct 
{
    int                     id;
    pthread_t               thread;
    pthread_cond_t          cond;
    pthread_mutex_t         mutex;
    int                     thr_id;
    uint32_t                joboffset;
    uint32_t                jobcount;
	bool					has_work;
    uint32_t                nonce_begin;
    uint32_t                endiandata[20];
    int                     hash_selection;
	bool					exit_thread;

    sph_simd512_context     ctx_simd;       //9
    sph_hamsi512_context    ctx_hamsi;      //B
    sph_fugue512_context    ctx_fugue;      //C
} subthread_t;

static uint32_t *d_hash[MAX_GPUS];
static uint32_t *h_hash[MAX_GPUS];
static subthread_t *sub_threads[MAX_GPUS];

// CPU HASH
inline int get_hash_selection(const uint8_t *prev_block_hash, int index)
{
    uint8_t nibble = prev_block_hash[7 - (index / 2)];
    if (index % 2 == 0)
    {
        return nibble >> 4;
    }
    else
    {
        return nibble & 0x0f;
    }
}

extern "C" void x16rhash(void *output, const void *input)
{
    sph_blake512_context     ctx_blake;      //0
    sph_bmw512_context       ctx_bmw;        //1
    sph_groestl512_context   ctx_groestl;    //2
    sph_jh512_context        ctx_jh;         //3
    sph_keccak512_context    ctx_keccak;     //4
    sph_skein512_context     ctx_skein;      //5
    sph_luffa512_context     ctx_luffa;      //6
    sph_cubehash512_context  ctx_cubehash;   //7
    sph_shavite512_context   ctx_shavite;    //8
    sph_simd512_context      ctx_simd;       //9
    sph_echo512_context      ctx_echo;       //A
    sph_hamsi512_context     ctx_hamsi;      //B
    sph_fugue512_context     ctx_fugue;      //C
    sph_shabal512_context    ctx_shabal;     //D
    sph_whirlpool_context    ctx_whirlpool;  //E
    sph_sha512_context       ctx_sha512;     //F

    uchar _ALIGN(64) hash[64];
    uint32_t *phash = (uint32_t *) hash;
    uint8_t *prev_block_hash = (uint8_t *) input + 4;

    for (int i = 0; i < X16R_HASH_COUNT; i++)
    {
        int length;
        if (i == 0)
        {
            length = 80;
        }
        else
        {
            input = phash;
            length = 64;
        }

        int hash_selection = get_hash_selection(prev_block_hash, i);
        switch (hash_selection)
        {
            case X16R_BLAKE:
                sph_blake512_init(&ctx_blake);
                sph_blake512(&ctx_blake, input, length);
                sph_blake512_close(&ctx_blake, phash);
                break;
            case X16R_BMW:
                sph_bmw512_init(&ctx_bmw);
                sph_bmw512(&ctx_bmw, input, length);
                sph_bmw512_close(&ctx_bmw, phash);
                break;
            case X16R_GROESTL:
                sph_groestl512_init(&ctx_groestl);
                sph_groestl512(&ctx_groestl, input, length);
                sph_groestl512_close(&ctx_groestl, phash);
                break;
            case X16R_JH:
                sph_jh512_init(&ctx_jh);
                sph_jh512(&ctx_jh, input, length);
                sph_jh512_close(&ctx_jh, phash);
                break;
            case X16R_KECCAK:
                sph_keccak512_init(&ctx_keccak);
                sph_keccak512(&ctx_keccak, input, length);
                sph_keccak512_close(&ctx_keccak, phash);
                break;
            case X16R_SKEIN:
                sph_skein512_init(&ctx_skein);
                sph_skein512(&ctx_skein, input, length);
                sph_skein512_close(&ctx_skein, phash);
                break;
            case X16R_LUFFA:
                sph_luffa512_init(&ctx_luffa);
                sph_luffa512(&ctx_luffa, input, length);
                sph_luffa512_close(&ctx_luffa, phash);
                break;
            case X16R_CUBEHASH:
                sph_cubehash512_init(&ctx_cubehash);
                sph_cubehash512(&ctx_cubehash, input, length);
                sph_cubehash512_close(&ctx_cubehash, phash);
                break;
            case X16R_SHAVITE:
                sph_shavite512_init(&ctx_shavite);
                sph_shavite512(&ctx_shavite, input, length);
                sph_shavite512_close(&ctx_shavite, phash);
                break;
            case X16R_SIMD:
                sph_simd512_init(&ctx_simd);
                sph_simd512(&ctx_simd, input, length);
                sph_simd512_close(&ctx_simd, phash);
                break;
            case X16R_ECHO:
                sph_echo512_init(&ctx_echo);
                sph_echo512(&ctx_echo, input, length);
                sph_echo512_close(&ctx_echo, phash);
                break;
            case X16R_HAMSI:
                sph_hamsi512_init(&ctx_hamsi);
                sph_hamsi512(&ctx_hamsi, input, length);
                sph_hamsi512_close(&ctx_hamsi, phash);
                break;
            case X16R_FUGUE:
                sph_fugue512_init(&ctx_fugue);
                sph_fugue512(&ctx_fugue, input, length);
                sph_fugue512_close(&ctx_fugue, phash);
                break;
            case X16R_SHABAL:
                sph_shabal512_init(&ctx_shabal);
                sph_shabal512(&ctx_shabal, input, length);
                sph_shabal512_close(&ctx_shabal, phash);
                break;
            case X16R_WHIRLPOOL:
                sph_whirlpool_init(&ctx_whirlpool);
                sph_whirlpool(&ctx_whirlpool, input, length);
                sph_whirlpool_close(&ctx_whirlpool, phash);
                break;
            case X16R_SHA512:
                sph_sha512_init(&ctx_sha512);
                sph_sha512(&ctx_sha512, input, length);
                sph_sha512_close(&ctx_sha512, phash);
                break;
            default:
                gpulog(LOG_ERR, -1, "Unknown hash selection: %d (this should never happen!)", hash_selection);
                break;
        }
    }
    memcpy(output, phash, 32);
}

//#define _DEBUG
#define _DEBUG_PREFIX "x16r"
#include "cuda_debug.cuh"

static void *scanhash_cpufallback_thread(void *userdata)
{
    subthread_t& subthread = *((subthread_t*)userdata);

	pthread_mutex_lock(&subthread.mutex);

	while (1)
    {
		while (!subthread.has_work)
		{
			pthread_cond_wait(&subthread.cond, &subthread.mutex);

			if (subthread.exit_thread)
			{
				break;
			}
		}

		if (subthread.exit_thread)
		{
			pthread_mutex_unlock(&subthread.mutex);

			break;
		}

		for (uint32_t i = subthread.joboffset; i < subthread.joboffset + subthread.jobcount; i++)
        {
            uint32_t* target_hash = &h_hash[subthread.thr_id][16 * i];
            be32enc(&subthread.endiandata[19], subthread.nonce_begin + i);
            
            switch (subthread.hash_selection)
            {
                case X16R_SIMD:
                    sph_simd512_init(&subthread.ctx_simd);
                    sph_simd512(&subthread.ctx_simd, subthread.endiandata, 80);
                    sph_simd512_close(&subthread.ctx_simd, target_hash);
                    break;
                case X16R_HAMSI:
                    sph_hamsi512_init(&subthread.ctx_hamsi);
                    sph_hamsi512(&subthread.ctx_hamsi, subthread.endiandata, 80);
                    sph_hamsi512_close(&subthread.ctx_hamsi, target_hash);
                    break;
                case X16R_FUGUE:
                    sph_fugue512_init(&subthread.ctx_fugue);
                    sph_fugue512(&subthread.ctx_fugue, subthread.endiandata, 80);
                    sph_fugue512_close(&subthread.ctx_fugue, target_hash);
                    break;
                default:
                    gpulog(LOG_ERR, subthread.thr_id, "hash selection not valid for cpu multithreading: %d (this should never happen!)", &subthread.hash_selection);
                    break;
            } 

			if (work_restart[subthread.thr_id].restart)
			{
				break;
			}
        }
	
        subthread.has_work = false;

		pthread_cond_signal(&subthread.cond);
    }

	pthread_mutex_unlock(&subthread.mutex);

	return NULL;
}


static bool init[MAX_GPUS] = { 0 };

extern "C" void wait_for_fallback_jobs(int thr_id, int num_sub_threads)
{
	for (int i = 0; i < num_sub_threads; ++i)
	{
		subthread_t& sub_thr = sub_threads[thr_id][i];

		pthread_mutex_lock(&sub_thr.mutex);

		while (sub_thr.has_work && !sub_thr.exit_thread)
		{
			pthread_cond_wait(&sub_thr.cond, &sub_thr.mutex);

			if (work_restart[thr_id].restart)
			{
				pthread_mutex_unlock(&sub_thr.mutex);
				break;
			}
		}

		pthread_mutex_unlock(&sub_thr.mutex);

		if (work_restart[thr_id].restart)
		{
			break;
		}
	}
}

extern "C" int scanhash_x16r(int thr_id, struct work* work, uint32_t max_nonce, unsigned long *hashes_done)
{
    uint32_t *pdata = work->data;
    uint32_t *ptarget = work->target;
    const uint32_t first_nonce = pdata[19];
    int intensity = (device_sm[device_map[thr_id]] >= 500 && !is_windows()) ? 20 : 19;
    uint32_t throughput = cuda_default_throughput(thr_id, 1U << intensity); // 19=256*256*8;

	// EXPERIMENTAL - this is to see if we can reduce the bottleneck with the GPUs waiting for the CPU.
	// It will greatly depend on the CPU to GPU ratio etc. 
	int intensity_reduction = opt_cpu_fb_intensity_reduction;

	int actual_intensity = (int)throughput2intensity(throughput);

	if (intensity_reduction < 0)
	{
		intensity_reduction = 0;
	}
	else if (intensity_reduction > actual_intensity - 1)
	{
		intensity_reduction = actual_intensity - 1;
	}

	// Note that we have to call all the *512_cpu_init with the full throughput, but it
	// appears that we can successfully run them all with lower throughput, which helps when
	// running a cpu-fallback block.
	uint32_t cpu_fallback_throughput = 1U << (actual_intensity - intensity_reduction);

	if (cpu_fallback_throughput < 256)
	{
		cpu_fallback_throughput = 256;
	}

    if (opt_benchmark)
    {
        ptarget[7] = 0x5;
    }

    int num_sub_threads = opt_n_cpu_fallback_threads;
            
    if (!init[thr_id])
    {
        cudaSetDevice(device_map[thr_id]);
        if (opt_cudaschedule == -1 && gpu_threads == 1)
        {
            cudaDeviceReset();
            // reduce cpu usage
            cudaSetDeviceFlags(cudaDeviceScheduleBlockingSync);
            CUDA_LOG_ERROR();
        }
        gpulog(LOG_INFO, thr_id, "Normal Intensity set to %g, %u cuda threads", throughput2intensity(throughput), throughput);
		gpulog(LOG_INFO, thr_id, "CPU-Fallback Intensity set to %g, %u cuda threads", throughput2intensity(cpu_fallback_throughput), cpu_fallback_throughput);

        quark_blake512_cpu_init(thr_id, throughput);
        quark_blake512_cpu_init(thr_id, throughput);
        quark_bmw512_cpu_init(thr_id, throughput);
        quark_groestl512_cpu_init(thr_id, throughput);
        quark_jh512_cpu_init(thr_id, throughput);
        quark_keccak512_cpu_init(thr_id, throughput);
        quark_skein512_cpu_init(thr_id, throughput);
        qubit_luffa512_cpu_init(thr_id, throughput);
        x11_luffa512_cpu_init(thr_id, throughput);
        x11_cubehash512_cpu_init(thr_id, throughput);
        x11_shavite512_cpu_init(thr_id, throughput);
        x11_simd512_cpu_init(thr_id, throughput);
        x13_hamsi512_cpu_init(thr_id, throughput);
        x13_fugue512_cpu_init(thr_id, throughput);
        x14_shabal512_cpu_init(thr_id, throughput);
        whirlpool512_init_sm3(thr_id, throughput, 0);
        x15_whirlpool_cpu_init(thr_id, throughput, 0);
		x16r_echo512_cpu_init(thr_id, throughput);
		x17_sha512_cpu_init(thr_id, throughput);

        CUDA_CALL_OR_RET_X(cudaMalloc(&d_hash[thr_id], (size_t) 64 * (size_t)throughput), 0);

        h_hash[thr_id] = (uint32_t*)malloc((size_t)64 * (size_t)throughput);
        
		if (opt_debug)
        {
            gpulog(LOG_DEBUG, thr_id, "Num CPU-Fallback subthreads  = %d", num_sub_threads);
        }

		cuda_check_cpu_init(thr_id, throughput);

		sub_threads[thr_id] = (subthread_t*)calloc(num_sub_threads, sizeof(subthread_t));

		for (int i = 0; i < num_sub_threads; ++i)
		{
			subthread_t& sub_thr = sub_threads[thr_id][i];

			sub_thr.jobcount = 0;
			sub_thr.has_work = false;
			sub_thr.id = i;
			sub_thr.thr_id = thr_id;
			sub_thr.exit_thread = false;

			int ret = pthread_mutex_init(&sub_thr.mutex, NULL);

			if (ret != 0)
			{
				gpulog(LOG_ERR, thr_id, "pthread_mutex_init : failed %d", ret);
			}

			ret = pthread_cond_init(&sub_thr.cond, NULL);

			if (ret != 0)
			{
				gpulog(LOG_ERR, thr_id, "pthread_cond_init : failed %d", ret);
			}

			ret = pthread_create(&sub_thr.thread, NULL, scanhash_cpufallback_thread, &sub_thr);

			if (ret != 0)
			{
				gpulog(LOG_ERR, thr_id, "pthread_create : failed %d", ret);
			}
		}

        init[thr_id] = true;
    }

    uint32_t endiandata[20];
    
    for (int i = 0; i < 20; i++)
    {
        be32enc(&endiandata[i], pdata[i]);
    }

    uint8_t *prev_block_hash = (uint8_t *) endiandata + 4;
    int hash_selection[X16R_HASH_COUNT];
    for (int i = 0; i < X16R_HASH_COUNT; i++)
    {
        hash_selection[i] = get_hash_selection(prev_block_hash, i);
    }

    if (opt_debug)
    {
        applog_hex((void *) endiandata, 80);
        applog_hex((void *) ptarget, 32);
        gpulog(LOG_DEBUG, thr_id, "hash selection: %s-%s-%s-%s-%s-%s-%s-%s-%s-%s-%s-%s-%s-%s-%s-%s",
            hash_names[hash_selection[0]],
            hash_names[hash_selection[1]],
            hash_names[hash_selection[2]],
            hash_names[hash_selection[3]],
            hash_names[hash_selection[4]],
            hash_names[hash_selection[5]],
            hash_names[hash_selection[6]],
            hash_names[hash_selection[7]],
            hash_names[hash_selection[8]],
            hash_names[hash_selection[9]],
            hash_names[hash_selection[10]],
            hash_names[hash_selection[11]],
            hash_names[hash_selection[12]],
            hash_names[hash_selection[13]],
            hash_names[hash_selection[14]],
            hash_names[hash_selection[15]]
        );
    }

    bool cpuFallback = false;
    bool new_gpu_algo = false;

	switch (hash_selection[0])
	{
	case X16R_BLAKE:
		quark_blake512_cpu_setBlock_80(thr_id, endiandata);
		break;
	case X16R_BMW:
		quark_bmw512_cpu_setBlock_80(endiandata);
		break;
	case X16R_GROESTL:
		groestl512_setBlock_80(thr_id, endiandata);
		break;
	case X16R_JH:
		jh512_setBlock_80(thr_id, endiandata);
		break;
	case X16R_KECCAK:
		keccak512_setBlock_80(thr_id, endiandata);
		break;
	case X16R_SKEIN:
		skein512_cpu_setBlock_80(endiandata);
		break;
	case X16R_LUFFA:
		qubit_luffa512_cpu_setBlock_80(endiandata);
		break;
	case X16R_CUBEHASH:
		cubehash512_setBlock_80(thr_id, endiandata);
		break;
	case X16R_SHAVITE:
		x11_shavite512_setBlock_80(endiandata);
		break;
	case X16R_ECHO:
		x16r_echo512_cpu_setBlock_80(endiandata);
		new_gpu_algo = true;
		break;
	case X16R_WHIRLPOOL:
		whirlpool512_setBlock_80_sm3((void*)endiandata, ptarget);
		break;
	case X16R_SHABAL:
		x14_shabal512_setBlock_80(thr_id, endiandata);
		new_gpu_algo = true;
		break;
	case X16R_SHA512:
		x17_sha512_setBlock_80(thr_id, endiandata);
		new_gpu_algo = true;
		break;
	case X16R_SIMD:
		cpuFallback = true;
		if (opt_debug)
		{
			gpulog(LOG_DEBUG, thr_id, "Not yet implemented: simd512/80 (falling back on CPU for first round)");
		}
		break;
	case X16R_HAMSI:
		cpuFallback = true;
		if (opt_debug)
		{
			gpulog(LOG_DEBUG, thr_id, "Not yet implemented: hamsi512/80 (falling back on CPU for first round)");
		}
		break;
	case X16R_FUGUE:
		cpuFallback = true;
		if (opt_debug)
		{
			gpulog(LOG_DEBUG, thr_id, "Not yet implemented: fugue512/80 (falling back on CPU for first round)");
		}
		break;
	default:
		gpulog(LOG_ERR, thr_id, "Unknown hash selection: %d (this should never happen!)", hash_selection[0]);
		break;
	}

    cuda_check_cpu_setTarget(ptarget);

	if (cpuFallback)
	{
		gpulog(LOG_INFO, thr_id, "Partial GPU job - first round is CPU (%d threads).", num_sub_threads);

		throughput = cpu_fallback_throughput;
	}
	else
	{
		if (new_gpu_algo)
		{
			if (use_colors)
			{
				gpulog(LOG_INFO, thr_id, "100%% GPU job. \x1B[36m(New GPU Algorithm : %s)\x1B[0m", hash_names[hash_selection[0]]);
			}
			else
			{
				gpulog(LOG_INFO, thr_id, "100%% GPU job. (New GPU Algorithm : %s)", hash_names[hash_selection[0]]);
			}
		}
		else
		{
			gpulog(LOG_INFO, thr_id, "100%% GPU job.");
		}
	}

	bool first_pass = true;
	bool last_was_invalid = false;

	// There is a slight chance we bailed out while jobs were running, and whilst unlikely, they still be running.
	wait_for_fallback_jobs(thr_id, num_sub_threads);

	int num = (int)(throughput / num_sub_threads);
	int extra = throughput - (num * num_sub_threads);

	int start = 0;

	for (int i = 0; i < num_sub_threads; ++i)
	{
		subthread_t& sub_thr = sub_threads[thr_id][i];

		sub_thr.joboffset = start;
		sub_thr.jobcount = num;

		if (i < extra)
		{
			sub_thr.jobcount++;
		}

		start += sub_thr.jobcount;
	}

    do
    {
        int order = 0;

		if (!cpuFallback)
		{
			switch (hash_selection[0])
			{
			case X16R_BLAKE:
				quark_blake512_cpu_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id]); order++;
				break;
			case X16R_BMW:
				quark_bmw512_cpu_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id], order++);
				break;
			case X16R_GROESTL:
				groestl512_cuda_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id]); order++;
				break;
			case X16R_JH:
				jh512_cuda_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id]); order++;
				break;
			case X16R_KECCAK:
				keccak512_cuda_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id]); order++;
				break;
			case X16R_SKEIN:
				skein512_cpu_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id], 1); order++;
				break;
			case X16R_LUFFA:
				qubit_luffa512_cpu_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id], order++);
				break;
			case X16R_CUBEHASH:
				cubehash512_cuda_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id]); order++;
				break;
			case X16R_SHAVITE:
				x11_shavite512_cpu_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id], order++);
				break;
			case X16R_WHIRLPOOL:
				whirlpool512_hash_80_sm3(thr_id, throughput, pdata[19], d_hash[thr_id], order++);
				break;
			case X16R_SHA512:
				x17_sha512_cpu_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id], order++);
				break;
			case X16R_SHABAL:
				x14_shabal512_cpu_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id], order++);
				break;
			case X16R_ECHO:
				x16r_echo512_cpu_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id], order++);
				break;
			case X16R_SIMD:
			case X16R_HAMSI:
			case X16R_FUGUE:
				// Now handled on separate threads.
				break;
			default:
				gpulog(LOG_ERR, thr_id, "Round %d unknown hash selection: %d (this should never happen!)", 0, hash_selection[0]);
				break;
			}
		}

		// FIXME: CPU fallback for unimplemented first round algorithms
        if (cpuFallback)
        {   
			if (run_parallel_fallback_jobs && last_was_invalid)
			{
				// we need to discard the pre-emptive cpu-fallback jobs, as the start nonce has been changed.
				wait_for_fallback_jobs(thr_id, num_sub_threads);
			}

			if (work_restart[thr_id].restart)
			{
				break;
			}

			if (!run_parallel_fallback_jobs || first_pass || last_was_invalid)
			{
				for (int i = 0; i < num_sub_threads; ++i)
				{
					subthread_t& sub_thr = sub_threads[thr_id][i];

					pthread_mutex_lock(&sub_thr.mutex);

					sub_thr.hash_selection = hash_selection[0];

					memcpy(sub_thr.endiandata, endiandata, sizeof(endiandata));

					sub_thr.nonce_begin = pdata[19];
					sub_thr.has_work = true;

					pthread_cond_signal(&sub_thr.cond);
					pthread_mutex_unlock(&sub_thr.mutex);
				}
			}

			wait_for_fallback_jobs(thr_id, num_sub_threads);

			if (work_restart[thr_id].restart)
			{
				break;
			}

			cudaError ret = cudaMemcpy(d_hash[thr_id], h_hash[thr_id], 64 * (size_t)throughput, cudaMemcpyHostToDevice);

			if (run_parallel_fallback_jobs)
			{
				first_pass = false;

				if ((uint64_t)pdata[19] + (uint64_t)(throughput * 2) <= max_nonce)
				{
					// start the next set of cpu jobs in parallel with the gpu work.
				
					for (int i = 0; i < num_sub_threads; ++i)
					{
						subthread_t& sub_thr = sub_threads[thr_id][i];

						pthread_mutex_lock(&sub_thr.mutex);

						sub_thr.hash_selection = hash_selection[0];

						memcpy(sub_thr.endiandata, endiandata, sizeof(endiandata));

						sub_thr.nonce_begin = pdata[19] + throughput;
						sub_thr.has_work = true;

						pthread_cond_signal(&sub_thr.cond);
						pthread_mutex_unlock(&sub_thr.mutex);
					}
				}
			}
		}

		last_was_invalid = false;

		if (work_restart[thr_id].restart)
		{
			break;
		}

		for (int i = 1; i < X16R_HASH_COUNT; i++)
		{
			switch (hash_selection[i])
			{
			case X16R_BLAKE:
				quark_blake512_cpu_hash_64(thr_id, throughput, pdata[19], NULL, d_hash[thr_id], order++);
				break;
			case X16R_BMW:
				quark_bmw512_cpu_hash_64(thr_id, throughput, pdata[19], NULL, d_hash[thr_id], order++);
				break;
			case X16R_GROESTL:
				quark_groestl512_cpu_hash_64(thr_id, throughput, pdata[19], NULL, d_hash[thr_id], order++);
				break;
			case X16R_JH:
				quark_jh512_cpu_hash_64(thr_id, throughput, pdata[19], NULL, d_hash[thr_id], order++);
				break;
			case X16R_KECCAK:
				quark_keccak512_cpu_hash_64(thr_id, throughput, pdata[19], NULL, d_hash[thr_id], order++);
				break;
			case X16R_SKEIN:
				quark_skein512_cpu_hash_64(thr_id, throughput, pdata[19], NULL, d_hash[thr_id], order++);
				break;
			case X16R_LUFFA:
				x11_luffa512_cpu_hash_64(thr_id, throughput, pdata[19], NULL, d_hash[thr_id], order++);
				break;
			case X16R_CUBEHASH:
				x11_cubehash512_cpu_hash_64(thr_id, throughput, pdata[19], NULL, d_hash[thr_id], order++);
				break;
			case X16R_SHAVITE:
				x11_shavite512_cpu_hash_64(thr_id, throughput, pdata[19], NULL, d_hash[thr_id], order++);
				break;
			case X16R_SIMD:
				x11_simd512_cpu_hash_64(thr_id, throughput, pdata[19], NULL, d_hash[thr_id], order++);
				break;
			case X16R_ECHO:
				x16r_echo512_cpu_hash_64(thr_id, throughput, pdata[19], NULL, d_hash[thr_id], order++);
				break;
			case X16R_HAMSI:
				x13_hamsi512_cpu_hash_64(thr_id, throughput, pdata[19], NULL, d_hash[thr_id], order++);
				break;
			case X16R_FUGUE:
				x13_fugue512_cpu_hash_64(thr_id, throughput, pdata[19], NULL, d_hash[thr_id], order++);
				break;
			case X16R_SHABAL:
				x14_shabal512_cpu_hash_64(thr_id, throughput, pdata[19], NULL, d_hash[thr_id], order++);
				break;
			case X16R_WHIRLPOOL:
				x15_whirlpool_cpu_hash_64(thr_id, throughput, pdata[19], NULL, d_hash[thr_id], order++);
				break;
			case X16R_SHA512:
				x17_sha512_cpu_hash_64(thr_id, throughput, pdata[19], d_hash[thr_id]); order++;
				break;
			default:
				gpulog(LOG_ERR, thr_id, "Round %d unknown hash selection: %d (this should never happen!)", i, hash_selection[i]);
				break;
			}

			if(work_restart[thr_id].restart)
			{
				break;
			}
        }

        *hashes_done = pdata[19] - first_nonce + throughput;

        work->nonces[0] = cuda_check_hash(thr_id, throughput, pdata[19], d_hash[thr_id]);
        if (work->nonces[0] != UINT32_MAX)
        {
            const uint32_t Htarg = ptarget[7];
            uint32_t _ALIGN(64) vhash[8];
            be32enc(&endiandata[19], work->nonces[0]);
            x16rhash(vhash, endiandata);
            if (vhash[7] <= Htarg && fulltest(vhash, ptarget))
            {
                work->valid_nonces = 1;
                work_set_target_ratio(work, vhash);
                work->nonces[1] = cuda_check_hash_suppl(thr_id, throughput, pdata[19], d_hash[thr_id], 1);
                if (work->nonces[1] != 0)
                {
                    be32enc(&endiandata[19], work->nonces[1]);
                    x16rhash(vhash, endiandata);
                    bn_set_target_ratio(work, vhash, 1);
                    work->valid_nonces++;
                    pdata[19] = max(work->nonces[0], work->nonces[1]) + 1;
                }
                else
                {
                    pdata[19] = work->nonces[0] + 1;
                }
                return work->valid_nonces;
            }
            else
            {
                gpu_increment_reject(thr_id);
                if (!opt_quiet)
                {
                    gpulog(LOG_WARNING, thr_id, "result for %08x does not validate on CPU!", work->nonces[0]);
                }
                pdata[19] = work->nonces[0] + 1;
				last_was_invalid = true;
                continue;
            }
        }

        if ((uint64_t) throughput + pdata[19] >= max_nonce)
        {
            pdata[19] = max_nonce;
            break;
        }
        pdata[19] += throughput;

    }
    while (!work_restart[thr_id].restart);

    *hashes_done = pdata[19] - first_nonce;
    return 0;
}

// cleanup
extern "C" void free_x16r(int thr_id)
{
    if (!init[thr_id])
    {
        return;
    }

    cudaThreadSynchronize();

	int num_sub_threads = opt_n_cpu_fallback_threads;

	if (opt_debug)
	{
		gpulog(LOG_DEBUG, thr_id, "Ending CPU-Fallback subthreads...");
	}

	for (int i = 0; i < num_sub_threads; ++i)
	{
		subthread_t& sub_thr = sub_threads[thr_id][i];

		sub_thr.exit_thread = true;

		pthread_mutex_lock(&sub_thr.mutex);
		pthread_cond_signal(&sub_thr.cond);
		pthread_mutex_unlock(&sub_thr.mutex);

		void* ret;

		pthread_join(sub_thr.thread, &ret);
		
   		pthread_mutex_destroy(&sub_thr.mutex);
		pthread_cond_destroy(&sub_thr.cond);
	}


	if (opt_debug)
	{
		gpulog(LOG_DEBUG, thr_id, "Finished CPU-Fallback subthreads.");
	}

    cudaFree(d_hash[thr_id]);
	free(h_hash[thr_id]);
	free(sub_threads[thr_id]);

    quark_blake512_cpu_free(thr_id);
    quark_groestl512_cpu_free(thr_id);
    x11_simd512_cpu_free(thr_id);
    x13_fugue512_cpu_free(thr_id);
    whirlpool512_free_sm3(thr_id);
    x15_whirlpool_cpu_free(thr_id);
	x14_shabal512_cpu_free(thr_id);
	x17_sha512_cpu_free(thr_id);
    cuda_check_cpu_free(thr_id);
    init[thr_id] = false;

    cudaDeviceSynchronize();
}
