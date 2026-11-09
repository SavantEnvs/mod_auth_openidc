/*
 * Fuzz target for oidc_state_cookies_clean_expired(): the walk over the Cookie request header that the
 * module runs, before any session or state validation, whenever a new authentication flow starts and
 * on the redirect-URI callback. The input is the raw header value an unauthenticated client sends.
 *
 * Each input runs on its own pool with its own allocator, freed afterwards, and the memory blocks that
 * allocator hands the pool are zeroed first. A pool is carved out of larger malloc'd blocks, so what
 * follows a string in it is whatever the block held before; zeroing it makes every input's result depend
 * on that input only, not on the heap history of the process that replays it.
 */

#include <apr_allocator.h>
#include <apr_pools.h>
#include <apr_strings.h>
#include <apr_tables.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "state.h"
#include "util.h" /* test fixture */

static int g_ready = 0;

int LLVMFuzzerInitialize(int *argc, char ***argv) {
	(void)argc;
	(void)argv;
	if (!g_ready) {
		oidc_test_setup();
		g_ready = 1;
	}
	return 0;
}

#define BLOCK_SIZE 8192
#define PRIMED_BLOCKS 3

/* hand the allocator zeroed blocks: two pool-sized ones and PRIMED_BLOCKS big enough for the header copies */
static void prime_allocator(apr_allocator_t *allocator, size_t size) {
	apr_memnode_t *nodes[PRIMED_BLOCKS + 2];
	size_t n = 0, i;
	size_t big = ((size + 1 + BLOCK_SIZE + 4095) / 4096) * 4096;

	for (i = 0; i < PRIMED_BLOCKS + 2; i++) {
		nodes[n] = apr_allocator_alloc(allocator, i < 2 ? BLOCK_SIZE : big);
		if (nodes[n] != NULL) {
			memset(nodes[n]->first_avail, 0, nodes[n]->endp - nodes[n]->first_avail);
			n++;
		}
	}
	while (n > 0)
		apr_allocator_free(allocator, nodes[--n]);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
	if (!g_ready)
		LLVMFuzzerInitialize(NULL, NULL);

	apr_allocator_t *allocator = NULL;
	apr_pool_t *pool = NULL;
	apr_allocator_create(&allocator);
	prime_allocator(allocator, size);
	apr_pool_create_ex(&pool, NULL, NULL, allocator);

	request_rec r = *oidc_test_request_get();
	r.pool = pool;
	r.headers_in = apr_table_make(pool, 2);
	r.headers_out = apr_table_make(pool, 2);
	r.err_headers_out = apr_table_make(pool, 2);

	char *cookie = apr_palloc(pool, size + 1);
	if (size > 0)
		memcpy(cookie, data, size);
	cookie[size] = '\0';
	apr_table_set(r.headers_in, "Cookie", cookie);

	oidc_state_cookies_clean_expired(&r, oidc_test_cfg_get(), NULL, 0);

	apr_pool_destroy(pool);
	apr_allocator_destroy(allocator);
	return 0;
}
