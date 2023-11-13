/*
 * Copyright (c) 2014-2015, magnum
 * Copyright (c) 2015, Sayantan Datta <sdatta@openwall.com>
 * This software is hereby released to the general public under
 * the following terms: Redistribution and use in source and binary
 * forms, with or without modification, are permitted.
 */

#include "opencl_device_info.h"
#define AMD_PUTCHAR_NOCAST
#include "opencl_misc.h"
#include "opencl_mask.h"
#include "opencl_sha1.h"

#if BITMAP_SIZE_BITS_LESS_ONE < 0xffffffff
#define BITMAP_SIZE_BITS (BITMAP_SIZE_BITS_LESS_ONE + 1)
#else
#error BITMAP_SIZE_BITS is not defined
#endif

inline void cmp_final(uint gid,
		uint iter,
		__private uint *hash,
		__global uint *offset_table,
		__global uint *hash_table,
		__global uint *return_hashes,
		volatile __global uint *output,
		volatile __global uint *bitmap_dupe) {

	uint t, offset_table_index, hash_table_index;
	unsigned long LO, MI, HI;
	unsigned long p;

	HI = (unsigned long)hash[4];
	MI = ((unsigned long)hash[3] << 32) | (unsigned long)hash[2];
	LO = ((unsigned long)hash[1] << 32) | (unsigned long)hash[0];

	p = (HI % OFFSET_TABLE_SIZE) * SHIFT128_OT_SZ;
	p += (MI % OFFSET_TABLE_SIZE) * SHIFT64_OT_SZ;
	p += LO % OFFSET_TABLE_SIZE;
	p %= OFFSET_TABLE_SIZE;
	offset_table_index = (unsigned int)p;

	//error: chances of overflow is extremely low.
	LO += (unsigned long)offset_table[offset_table_index];

	p = (HI % HASH_TABLE_SIZE) * SHIFT128_HT_SZ;
	p += (MI % HASH_TABLE_SIZE) * SHIFT64_HT_SZ;
	p += LO % HASH_TABLE_SIZE;
	p %= HASH_TABLE_SIZE;
	hash_table_index = (unsigned int)p;

	if (hash_table[hash_table_index] == hash[0])
	if (hash_table[HASH_TABLE_SIZE + hash_table_index] == hash[1])
	{
/*
 * Prevent duplicate keys from cracking same hash
 */
		if (!(atomic_or(&bitmap_dupe[hash_table_index/32], (1U << (hash_table_index % 32))) & (1U << (hash_table_index % 32)))) {
			t = atomic_inc(&output[0]);
			output[1 + 3 * t] = gid;
			output[2 + 3 * t] = iter;
			output[3 + 3 * t] = hash_table_index;
			return_hashes[2 * t] = hash[2];
			return_hashes[2 * t + 1] = hash[3];
		}
	}
}

inline void cmp(uint gid,
		uint iter,
		__private uint *hash,
#if USE_LOCAL_BITMAPS
		__local
#else
		__global
#endif
		uint *bitmaps,
		__global uint *offset_table,
		__global uint *hash_table,
		__global uint *return_hashes,
		volatile __global uint *output,
		volatile __global uint *bitmap_dupe) {
	uint bitmap_index, tmp = 1;

	hash[0] = SWAP32(hash[0]);
	hash[1] = SWAP32(hash[1]);
	hash[2] = SWAP32(hash[2]);
	hash[3] = SWAP32(hash[3]);
	hash[4] = SWAP32(hash[4]);

#if SELECT_CMP_STEPS > 4
	bitmap_index = hash[0] & (BITMAP_SIZE_BITS - 1);
	tmp &= (bitmaps[bitmap_index >> 5] >> (bitmap_index & 31)) & 1U;
	bitmap_index = (hash[0] >> 16) & (BITMAP_SIZE_BITS - 1);
	tmp &= (bitmaps[(BITMAP_SIZE_BITS >> 5) + (bitmap_index >> 5)] >> (bitmap_index & 31)) & 1U;
	bitmap_index = hash[1] & (BITMAP_SIZE_BITS - 1);
	tmp &= (bitmaps[(BITMAP_SIZE_BITS >> 4) + (bitmap_index >> 5)] >> (bitmap_index & 31)) & 1U;
	bitmap_index = (hash[1] >> 16) & (BITMAP_SIZE_BITS - 1);
	tmp &= (bitmaps[(BITMAP_SIZE_BITS >> 5) * 3 + (bitmap_index >> 5)] >> (bitmap_index & 31)) & 1U;
	bitmap_index = hash[2] & (BITMAP_SIZE_BITS - 1);
	tmp &= (bitmaps[(BITMAP_SIZE_BITS >> 3) + (bitmap_index >> 5)] >> (bitmap_index & 31)) & 1U;
	bitmap_index = (hash[2] >> 16) & (BITMAP_SIZE_BITS - 1);
	tmp &= (bitmaps[(BITMAP_SIZE_BITS >> 5) * 5 + (bitmap_index >> 5)] >> (bitmap_index & 31)) & 1U;
	bitmap_index = hash[3] & (BITMAP_SIZE_BITS - 1);
	tmp &= (bitmaps[(BITMAP_SIZE_BITS >> 5) * 6 + (bitmap_index >> 5)] >> (bitmap_index & 31)) & 1U;
	bitmap_index = (hash[3] >> 16) & (BITMAP_SIZE_BITS - 1);
	tmp &= (bitmaps[(BITMAP_SIZE_BITS >> 5) * 7 + (bitmap_index >> 5)] >> (bitmap_index & 31)) & 1U;
#elif SELECT_CMP_STEPS > 2
	bitmap_index = hash[3] & (BITMAP_SIZE_BITS - 1);
	tmp &= (bitmaps[bitmap_index >> 5] >> (bitmap_index & 31)) & 1U;
	bitmap_index = hash[2] & (BITMAP_SIZE_BITS - 1);
	tmp &= (bitmaps[(BITMAP_SIZE_BITS >> 5) + (bitmap_index >> 5)] >> (bitmap_index & 31)) & 1U;
	bitmap_index = hash[1] & (BITMAP_SIZE_BITS - 1);
	tmp &= (bitmaps[(BITMAP_SIZE_BITS >> 4) + (bitmap_index >> 5)] >> (bitmap_index & 31)) & 1U;
	bitmap_index = hash[0] & (BITMAP_SIZE_BITS - 1);
	tmp &= (bitmaps[(BITMAP_SIZE_BITS >> 5) * 3 + (bitmap_index >> 5)] >> (bitmap_index & 31)) & 1U;
#elif SELECT_CMP_STEPS > 1
	bitmap_index = hash[3] & (BITMAP_SIZE_BITS - 1);
	tmp &= (bitmaps[bitmap_index >> 5] >> (bitmap_index & 31)) & 1U;
	bitmap_index = hash[2] & (BITMAP_SIZE_BITS - 1);
	tmp &= (bitmaps[(BITMAP_SIZE_BITS >> 5) + (bitmap_index >> 5)] >> (bitmap_index & 31)) & 1U;
#else
	bitmap_index = hash[3] & BITMAP_SIZE_BITS_LESS_ONE;
	tmp &= (bitmaps[bitmap_index >> 5] >> (bitmap_index & 31)) & 1U;
#endif

	if (tmp)
		cmp_final(gid, iter, hash, offset_table, hash_table, return_hashes, output, bitmap_dupe);
}

#define USE_CONST_CACHE \
	(CONST_CACHE_SIZE >= (NUM_INT_KEYS * 4))

__kernel void sha1(__global uint *keys,
		  __global uint *index,
		  __global uint *int_key_loc,
#if USE_CONST_CACHE
		  constant
#else
		  __global
#endif
		  uint *int_keys
#if !defined(__OS_X__) && USE_CONST_CACHE && gpu_amd(DEVICE_INFO)
		__attribute__((max_constant_size (NUM_INT_KEYS * 4)))
#endif
		 , __constant uchar *salt,
		 __global uint *bitmaps,
		  __global uint *offset_table,
		  __global uint *hash_table,
		  __global uint *return_hashes,
		  volatile __global uint *out_hash_ids,
		  volatile __global uint *bitmap_dupe)
{
	uint i;
	uint gid = get_global_id(0);
	uint base = index[gid];
	uint W[16] = { 0 };
	uint len = base & 63;
	uint hash[5];
	unsigned int salt_len = salt[16];

#if NUM_INT_KEYS > 1 && !IS_STATIC_GPU_MASK
	uint ikl = int_key_loc[gid];
	uint loc0 = ikl & 0xff;
#if MASK_FMT_INT_PLHDR > 1
#if LOC_1 >= 0
	uint loc1 = (ikl & 0xff00) >> 8;
#endif
#endif
#if MASK_FMT_INT_PLHDR > 2
#if LOC_2 >= 0
	uint loc2 = (ikl & 0xff0000) >> 16;
#endif
#endif
#if MASK_FMT_INT_PLHDR > 3
#if LOC_3 >= 0
	uint loc3 = (ikl & 0xff000000) >> 24;
#endif
#endif
#endif

#if !IS_STATIC_GPU_MASK
#define GPU_LOC_0 loc0
#define GPU_LOC_1 loc1
#define GPU_LOC_2 loc2
#define GPU_LOC_3 loc3
#else
#define GPU_LOC_0 LOC_0
#define GPU_LOC_1 LOC_1
#define GPU_LOC_2 LOC_2
#define GPU_LOC_3 LOC_3
#endif

#if USE_LOCAL_BITMAPS
	uint lid = get_local_id(0);
	uint lws = get_local_size(0);
	uint __local s_bitmaps[(BITMAP_SIZE_BITS >> 5) * SELECT_CMP_STEPS];

	for (i = 0; i < (((BITMAP_SIZE_BITS >> 5) * SELECT_CMP_STEPS) / lws); i++)
		s_bitmaps[i*lws + lid] = bitmaps[i*lws + lid];

	barrier(CLK_LOCAL_MEM_FENCE);
#endif

	keys += base >> 6;

	for (i = 0; i < (len+3)/4; i++)
		W[i] = SWAP32(*keys++);

	i--;
	if ((len & 3) == 0) {
		W[i + 1] = (((uint)salt[0] << 24) | ((uint)salt[1] << 16) | ((uint)salt[2] << 8) | (uint)salt[3]);
		W[i + 2] = (((uint)salt[4] << 24) | ((uint)salt[5] << 16) | ((uint)salt[6] << 8) | (uint)salt[7]);
		W[i + 3] = (((uint)salt[8] << 24) | ((uint)salt[9] << 16) | ((uint)salt[10] << 8) | (uint)salt[11]);
		W[i + 4] = (((uint)salt[12] << 24) | ((uint)salt[13] << 16) | ((uint)salt[14] << 8) | (uint)salt[15]);
	}
	if ((len & 3) == 1) {
		W[i] |= (((uint)salt[0] << 16) | ((uint)salt[1] << 8) | (uint)salt[2]);
		W[i + 1] = (((uint)salt[3] << 24) | ((uint)salt[4] << 16) | ((uint)salt[5] << 8) | (uint)salt[6]);
		W[i + 2] = (((uint)salt[7] << 24) | ((uint)salt[8] << 16) | ((uint)salt[9] << 8) | (uint)salt[10]);
		W[i + 3] = (((uint)salt[11] << 24) | ((uint)salt[12] << 16) | ((uint)salt[13] << 8) | (uint)salt[14]);
		W[i + 4] = (uint)salt[15] << 24;

	}
	if ((len & 3) == 2) {
		W[i] |= (((uint)salt[0] << 8) | (uint)salt[1]);
		W[i + 1] = (((uint)salt[2] << 24) | ((uint)salt[3] << 16) | ((uint)salt[4] << 8) | (uint)salt[5]);
		W[i + 2] = (((uint)salt[6] << 24) | ((uint)salt[7] << 16) | ((uint)salt[8] << 8) | (uint)salt[9]);
		W[i + 3] = (((uint)salt[10] << 24) | ((uint)salt[11] << 16) | ((uint)salt[12] << 8) | (uint)salt[13]);
		W[i + 4] = (((uint)salt[14] << 24) | ((uint)salt[15] << 16));

	}
	if ((len & 3) == 3) {
		W[i] |= (uint)salt[0];
		W[i + 1] = (((uint)salt[1] << 24) | ((uint)salt[2] << 16) | ((uint)salt[3] << 8) | (uint)salt[4]);
		W[i + 2] = (((uint)salt[5] << 24) | ((uint)salt[6] << 16) | ((uint)salt[7] << 8) | (uint)salt[8]);
		W[i + 3] = (((uint)salt[9] << 24) | ((uint)salt[10] << 16) | ((uint)salt[11] << 8) | (uint)salt[12]);
		W[i + 4] = (((uint)salt[13] << 24) | ((uint)salt[14] << 16) | ((uint)salt[15] << 8));
	}

	PUTCHAR_BE(W, (len + salt_len), 0x80);
	W[15] = (len + salt_len) << 3;

	for (i = 0; i < NUM_INT_KEYS; i++) {
#if NUM_INT_KEYS > 1
		PUTCHAR_BE(W, GPU_LOC_0, (int_keys[i] & 0xff));

#if MASK_FMT_INT_PLHDR > 1
#if LOC_1 >= 0
		PUTCHAR_BE(W, GPU_LOC_1, ((int_keys[i] & 0xff00) >> 8));
#endif
#endif
#if MASK_FMT_INT_PLHDR > 2
#if LOC_2 >= 0
		PUTCHAR_BE(W, GPU_LOC_2, ((int_keys[i] & 0xff0000) >> 16));
#endif
#endif
#if MASK_FMT_INT_PLHDR > 3
#if LOC_3 >= 0
		PUTCHAR_BE(W, GPU_LOC_3, ((int_keys[i] & 0xff000000) >> 24));
#endif
#endif
#endif
		sha1_init(hash);
		sha1_block(uint, W, hash);

		cmp(gid, i, hash,
#if USE_LOCAL_BITMAPS
		    s_bitmaps
#else
		    bitmaps
#endif
		    , offset_table, hash_table, return_hashes, out_hash_ids, bitmap_dupe);
	}
}
