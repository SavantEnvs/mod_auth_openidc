/*
 * Fuzz target for oidc_state_cookies_clean_expired(): the walk over the Cookie request header that the
 * module runs, before any session or state validation, whenever a new authentication flow starts and
 * on the redirect-URI callback. The input is the raw header value an unauthenticated client sends.
 *
 * Each input runs on its own pool with its own allocator, freed afterwards. APR hands the pool raw
 * page-aligned blocks that ASan does not see (no redzone), so an overread runs on into whatever mapping
 * happens to follow the block, and a stray '=' there ends it silently. To make the result depend on the
 * input only, the pool's first block is a fresh (zero-filled) one whose last page is inaccessible: a
 * scan that never finds its terminator always faults at the end of the block it started in.
 */

#include <apr_allocator.h>
#include <apr_pools.h>
#include <apr_strings.h>
#include <apr_tables.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>

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

#define PAGE 4096UL
#define FIRST_BLOCK (19 * PAGE)
#define MAX_GUARDED_INPUT (32 * 1024)

/*
 * Seed the allocator with one block that apr_pool_create_ex() takes as the pool's first block (it is the
 * only block on the free list, so nothing else is ever served from it). The usable part ends at the guard
 * page, which apr_palloc() honours through node->endp.
 */
static void prime_allocator(apr_allocator_t *allocator, size_t size) {
	if (size > MAX_GUARDED_INPUT)
		return;
	apr_memnode_t *node = apr_allocator_alloc(allocator, FIRST_BLOCK);
	if (node == NULL)
		return;
	uintptr_t end = (uintptr_t)node->endp;
	if (((uintptr_t)node % PAGE) == 0 && (end % PAGE) == 0 && end - (uintptr_t)node > 2 * PAGE &&
	    mprotect((void *)(end - PAGE), PAGE, PROT_NONE) == 0)
		node->endp = (char *)(end - PAGE);
	apr_allocator_free(allocator, node);
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
