/* aurora_tls: see aurora_tls.h. Built on BoringSSL. */
#include "aurora_tls.h"

#include <stdio.h>
#include <string.h>

#include <openssl/bio.h>
#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/mem.h>
#include <openssl/pool.h>
#include <openssl/sha2.h>
#include <openssl/ssl.h>

/* A byte queue: data in [off, len) of buf. Reading advances off; the buffer
 * is compacted only when it must grow, so each byte is moved at most once
 * per growth. (BoringSSL's memory BIO memmoves the remaining data on every
 * read, which is quadratic when a socket read hands over megabytes, as Linux
 * does.) */
typedef struct {
    uint8_t *buf;
    size_t off, len, cap;
} bq;

static size_t bq_size(const bq *q) { return q->len - q->off; }

static int bq_push(bq *q, const uint8_t *p, size_t n) {
    if (n == 0) return 1;
    if (q->off == q->len) q->off = q->len = 0;
    if (q->len + n > q->cap) {
        size_t live = bq_size(q);
        if (live + n <= q->cap) {
            memmove(q->buf, q->buf + q->off, live);
        } else {
            size_t cap = q->cap ? q->cap : 64 * 1024;
            while (cap < live + n) cap *= 2;
            uint8_t *nb = (uint8_t *)OPENSSL_malloc(cap);
            if (!nb) return 0;
            if (live) memcpy(nb, q->buf + q->off, live);
            OPENSSL_free(q->buf);
            q->buf = nb;
            q->cap = cap;
        }
        q->off = 0;
        q->len = live;
    }
    memcpy(q->buf + q->len, p, n);
    q->len += n;
    return 1;
}

static size_t bq_pop(bq *q, uint8_t *out, size_t n) {
    size_t live = bq_size(q);
    if (n > live) n = live;
    memcpy(out, q->buf + q->off, n);
    q->off += n;
    if (q->off == q->len) q->off = q->len = 0;
    return n;
}

static void bq_drop(bq *q, size_t n) {
    size_t live = bq_size(q);
    if (n >= live) {
        q->off = q->len = 0;
    } else {
        q->off += n;
    }
}

static void bq_free(bq *q) {
    OPENSSL_free(q->buf);
    q->buf = NULL;
    q->off = q->len = q->cap = 0;
}

struct at_conn {
    SSL *ssl;
    BIO *bio; /* one BIO both ways; SSL reads `in` and writes `out` */
    bq in;    /* ciphertext received, not yet read by SSL */
    bq out;   /* ciphertext produced, not yet sent by the caller */
    uint8_t pin[32];
    uint8_t seen[32];
    int have_seen;
    int pin_ok;
    int pin_failed;
    int handshake_done;
    char err[200];
};

static SSL_CTX *g_ctx;
static int g_ex_index = -1;
static BIO_METHOD *g_bio_method;

/* The BIO between SSL and the two queues. */
static int qbio_read(BIO *b, char *out, int outl) {
    at_conn *c = (at_conn *)BIO_get_data(b);
    BIO_clear_retry_flags(b);
    if (outl <= 0) return 0;
    if (bq_size(&c->in) == 0) {
        BIO_set_retry_read(b);
        return -1;
    }
    return (int)bq_pop(&c->in, (uint8_t *)out, (size_t)outl);
}

static int qbio_write(BIO *b, const char *in, int inl) {
    at_conn *c = (at_conn *)BIO_get_data(b);
    BIO_clear_retry_flags(b);
    if (inl <= 0) return 0;
    return bq_push(&c->out, (const uint8_t *)in, (size_t)inl) ? inl : -1;
}

static long qbio_ctrl(BIO *b, int cmd, long larg, void *parg) {
    at_conn *c = (at_conn *)BIO_get_data(b);
    (void)larg;
    (void)parg;
    switch (cmd) {
        case BIO_CTRL_FLUSH:
            return 1;
        case BIO_CTRL_PENDING:
            return (long)bq_size(&c->in);
        case BIO_CTRL_WPENDING:
            return (long)bq_size(&c->out);
        default:
            return 0;
    }
}

static int qbio_create(BIO *b) {
    BIO_set_init(b, 1);
    return 1;
}

static int qbio_destroy(BIO *b) {
    BIO_set_data(b, NULL);
    return 1;
}

/* Trust is the pin alone: the SHA-256 of the leaf certificate's DER. No CA,
 * chain, validity or name check (wire.PinnedTLS on the Go side). */
static enum ssl_verify_result_t verify_pin(SSL *ssl, uint8_t *out_alert) {
    at_conn *c = (at_conn *)SSL_get_ex_data(ssl, g_ex_index);
    const STACK_OF(CRYPTO_BUFFER) *chain = SSL_get0_peer_certificates(ssl);
    if (c == NULL || chain == NULL || sk_CRYPTO_BUFFER_num(chain) == 0) {
        if (c) c->pin_failed = 1;
        *out_alert = SSL_AD_BAD_CERTIFICATE;
        return ssl_verify_invalid;
    }
    const CRYPTO_BUFFER *leaf = sk_CRYPTO_BUFFER_value(chain, 0);
    SHA256(CRYPTO_BUFFER_data(leaf), CRYPTO_BUFFER_len(leaf), c->seen);
    c->have_seen = 1;
    if (CRYPTO_memcmp(c->seen, c->pin, 32) != 0) {
        c->pin_failed = 1;
        *out_alert = SSL_AD_BAD_CERTIFICATE;
        return ssl_verify_invalid;
    }
    c->pin_ok = 1;
    return ssl_verify_ok;
}

static int init_ctx(void) {
    if (g_ctx) return 1;
    SSL_CTX *ctx = SSL_CTX_new(TLS_with_buffers_method());
    if (!ctx) return 0;
    /* TLS 1.3 only: the agent requires it (wire.ServerTLS MinVersion). */
    if (!SSL_CTX_set_min_proto_version(ctx, TLS1_3_VERSION) ||
        !SSL_CTX_set_max_proto_version(ctx, TLS1_3_VERSION)) {
        SSL_CTX_free(ctx);
        return 0;
    }
    SSL_CTX_set_custom_verify(ctx, SSL_VERIFY_PEER, verify_pin);
    /* SSL_write may then return after some records are written. */
    SSL_CTX_set_mode(ctx, SSL_MODE_ENABLE_PARTIAL_WRITE);
    g_ex_index = SSL_get_ex_new_index(0, NULL, NULL, NULL, NULL);
    BIO_METHOD *m = BIO_meth_new(BIO_get_new_index() | BIO_TYPE_SOURCE_SINK, "aurora_queue");
    if (g_ex_index < 0 || !m || !BIO_meth_set_read(m, qbio_read) || !BIO_meth_set_write(m, qbio_write) ||
        !BIO_meth_set_ctrl(m, qbio_ctrl) || !BIO_meth_set_create(m, qbio_create) ||
        !BIO_meth_set_destroy(m, qbio_destroy)) {
        SSL_CTX_free(ctx);
        return 0;
    }
    g_bio_method = m;
    g_ctx = ctx;
    return 1;
}

/* The release tag of the bundled BoringSSL; the hook defines it. */
#ifndef AT_BORINGSSL_VERSION
#define AT_BORINGSSL_VERSION "unknown"
#endif

const char *at_version(void) { return "BoringSSL " AT_BORINGSSL_VERSION; }

at_conn *at_new(const uint8_t *pin, const char *server_name) {
    if (!init_ctx()) return NULL;
    at_conn *c = (at_conn *)OPENSSL_zalloc(sizeof *c);
    if (!c) return NULL;
    memcpy(c->pin, pin, 32);
    c->ssl = SSL_new(g_ctx);
    c->bio = BIO_new(g_bio_method);
    if (!c->ssl || !c->bio) goto fail;
    BIO_set_data(c->bio, c);
    SSL_set_ex_data(c->ssl, g_ex_index, c);
    SSL_set_connect_state(c->ssl);
    if (server_name && server_name[0] && !SSL_set_tlsext_host_name(c->ssl, server_name)) goto fail;
    /* One BIO for both directions: SSL takes one reference for each. */
    BIO_up_ref(c->bio);
    SSL_set_bio(c->ssl, c->bio, c->bio);
    c->bio = NULL;
    return c;
fail:
    if (c->ssl) SSL_free(c->ssl);
    if (c->bio) BIO_free(c->bio);
    OPENSSL_free(c);
    return NULL;
}

void at_free(at_conn *c) {
    if (!c) return;
    SSL_free(c->ssl); /* frees the BIO */
    bq_free(&c->in);
    bq_free(&c->out);
    OPENSSL_cleanse(c, sizeof *c);
    OPENSSL_free(c);
}

int at_feed(at_conn *c, const uint8_t *data, size_t len) {
    return bq_push(&c->in, data, len) ? AT_OK : AT_ERR_NOMEM;
}

static void set_err(at_conn *c, const char *what, int ssl_err) {
    uint32_t e = ERR_peek_last_error();
    char buf[120];
    if (e) {
        ERR_error_string_n(e, buf, sizeof buf);
    } else {
        snprintf(buf, sizeof buf, "ssl error %d", ssl_err);
    }
    snprintf(c->err, sizeof c->err, "%s: %s", what, buf);
    ERR_clear_error();
}

/* Maps an SSL_* failure to an AT_* code. */
static int fail(at_conn *c, const char *what, int ret) {
    int e = SSL_get_error(c->ssl, ret);
    if (e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE) {
        ERR_clear_error();
        return AT_WANT_IO;
    }
    if (c->pin_failed) {
        snprintf(c->err, sizeof c->err, "certificate pin mismatch");
        ERR_clear_error();
        return AT_ERR_PIN;
    }
    if (e == SSL_ERROR_ZERO_RETURN) {
        ERR_clear_error();
        return -AT_EOF;
    }
    set_err(c, what, e);
    return AT_ERR_TLS;
}

int at_handshake(at_conn *c) {
    if (c->handshake_done) return AT_OK;
    int r = SSL_do_handshake(c->ssl);
    if (r == 1) {
        /* Belt and braces: a finished handshake must have matched the pin. */
        if (!c->pin_ok || c->pin_failed) {
            c->pin_failed = 1;
            snprintf(c->err, sizeof c->err, "certificate pin mismatch");
            return AT_ERR_PIN;
        }
        c->handshake_done = 1;
        return AT_OK;
    }
    int code = fail(c, "handshake", r);
    return code == -AT_EOF ? AT_ERR_TLS : code;
}

int64_t at_write(at_conn *c, const uint8_t *data, size_t len) {
    if (!c->handshake_done) return AT_ERR_STATE;
    if (len == 0) return 0;
    if (len > 0x40000000) len = 0x40000000;
    int r = SSL_write(c->ssl, data, (int)len);
    if (r > 0) return r;
    int code = fail(c, "write", r);
    if (code == AT_WANT_IO) return 0;
    return code == -AT_EOF ? AT_ERR_TLS : code;
}

int64_t at_read(at_conn *c, uint8_t *buf, size_t len) {
    if (!c->handshake_done) return AT_ERR_STATE;
    if (len > 0x40000000) len = 0x40000000;
    int r = SSL_read(c->ssl, buf, (int)len);
    if (r > 0) return r;
    int code = fail(c, "read", r);
    if (code == AT_WANT_IO) return 0;
    return code;
}

size_t at_out_len(at_conn *c) { return bq_size(&c->out); }

const uint8_t *at_out_ptr(at_conn *c) {
    return c->out.buf ? c->out.buf + c->out.off : (const uint8_t *)"";
}

void at_consume(at_conn *c, size_t n) { bq_drop(&c->out, n); }

int at_close(at_conn *c) {
    int r = SSL_shutdown(c->ssl);
    if (r >= 0) return AT_OK;
    int code = fail(c, "close", r);
    return code == AT_WANT_IO || code == -AT_EOF ? AT_OK : code;
}

const char *at_error(at_conn *c) { return c->err; }

int at_peer_pin(at_conn *c, uint8_t out[32]) {
    if (!c->have_seen) return 0;
    memcpy(out, c->seen, 32);
    return 1;
}

const char *at_cipher(at_conn *c) {
    if (!c->handshake_done) return "";
    const SSL_CIPHER *ci = SSL_get_current_cipher(c->ssl);
    return ci ? SSL_CIPHER_standard_name(ci) : "";
}
