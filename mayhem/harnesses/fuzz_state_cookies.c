/*
 * Fuzz target for oidc_state_cookies_clean_expired(): the walk over the Cookie request header that the
 * module runs, before any session or state validation, whenever a new authentication flow starts and
 * on the redirect-URI callback. The input is the raw header value an unauthenticated client sends.
 *
 * Each input runs on its own pool with its own allocator, freed (not recycled) afterwards, so every
 * input starts from fresh heap and its result depends on that input only.
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

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
	if (!g_ready)
		LLVMFuzzerInitialize(NULL, NULL);

	apr_allocator_t *allocator = NULL;
	apr_pool_t *pool = NULL;
	apr_allocator_create(&allocator);
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
