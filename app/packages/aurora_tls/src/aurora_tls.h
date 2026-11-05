/* aurora_tls: a TLS 1.3 client engine over memory buffers, on BoringSSL.
 *
 * The caller owns the socket. It feeds received ciphertext with at_feed(),
 * sends what at_out_ptr()/at_out_len() hold and reports it with
 * at_consume(), and moves plaintext with at_read()/at_write(). Nothing here
 * blocks, starts a thread or touches the network.
 *
 * The peer is trusted by certificate pin only: the SHA-256 of the leaf
 * certificate's DER must equal the 32 bytes given to at_new(). There is no
 * CA, chain or host name check (agent/internal/wire/tls.go PinnedTLS).
 * Only TLS 1.3 is offered.
 */
#ifndef AURORA_TLS_H
#define AURORA_TLS_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#define AT_API __declspec(dllexport)
#else
#define AT_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct at_conn at_conn;

/* Results. */
#define AT_OK 0          /* done */
#define AT_WANT_IO 1     /* feed more ciphertext and/or send pending output */
#define AT_EOF 2         /* the peer closed the TLS session (close_notify) */
#define AT_ERR_PIN (-1)  /* certificate pin mismatch: never retry (D-62) */
#define AT_ERR_TLS (-2)  /* any other TLS failure; see at_error() */
#define AT_ERR_STATE (-3)
#define AT_ERR_NOMEM (-4)

/* Library version, for diagnostics. */
AT_API const char *at_version(void);

/* A new client. pin is 32 bytes. server_name may be NULL (no SNI). Returns
 * NULL on out of memory or when the crypto library cannot start. */
AT_API at_conn *at_new(const uint8_t *pin, const char *server_name);
AT_API void at_free(at_conn *c);

/* Received ciphertext; the engine copies it. AT_OK or AT_ERR_NOMEM. */
AT_API int at_feed(at_conn *c, const uint8_t *data, size_t len);

/* Drives the handshake: AT_OK once complete, AT_WANT_IO while it waits, or
 * an error. */
AT_API int at_handshake(at_conn *c);

/* Encrypts up to len bytes into the output queue. Returns the plaintext
 * bytes accepted (> 0), 0 when it cannot take any now, or an error (< 0). */
AT_API int64_t at_write(at_conn *c, const uint8_t *data, size_t len);

/* Decrypts into buf. Returns plaintext bytes (> 0), 0 when no whole record
 * is buffered, -AT_EOF when the peer closed, or an error (< 0). */
AT_API int64_t at_read(at_conn *c, uint8_t *buf, size_t len);

/* Ciphertext waiting to be sent. The pointer covers at_out_len() bytes and
 * stays valid until the next call into the engine. */
AT_API size_t at_out_len(at_conn *c);
AT_API const uint8_t *at_out_ptr(at_conn *c);
AT_API void at_consume(at_conn *c, size_t n);

/* Queues close_notify. */
AT_API int at_close(at_conn *c);

/* Message for the last error ("" when none). */
AT_API const char *at_error(at_conn *c);

/* SHA-256 of the peer's leaf certificate, once seen. 1 if set, else 0. */
AT_API int at_peer_pin(at_conn *c, uint8_t out[32]);

/* Negotiated cipher suite, or "" before the handshake ends. */
AT_API const char *at_cipher(at_conn *c);

#ifdef __cplusplus
}
#endif

#endif
