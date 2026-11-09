/* Force-included when building this old base: its sources rely on cjose 0.6's headers pulling in
 * OpenSSL (BIO, NID_*, EVP_*), which cjose 0.8.1, pinned in the Dockerfile, no longer does. */
#include <openssl/bio.h>
#include <openssl/ec.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/obj_mac.h>
#include <openssl/pem.h>
#include <openssl/rsa.h>
#include <openssl/x509.h>
