#ifndef RUST_H__
#define RUST_H__

/*
 * Rust runtime library.
 * Copyright 2008, 2009 Graydon Hoare <graydon@pobox.com>.
 * Released under MIT license.
 * See file COPYING for details.
 */

/*
 * Include this file after you've defined the ISO C9x stdint
 * types (size, uint8, uintptr, etc.)
 */

struct rust_proc;
struct rust_prog;
struct rust_port;
struct rust_chan;
struct rust_srv;
struct rust_rt;

typedef struct rust_proc rust_proc;
typedef struct rust_port rust_port;
typedef struct rust_chan rust_chan;
typedef struct rust_srv rust_srv;
typedef struct rust_rt rust_rt;

#ifdef __i386__
// 'cdecl' ABI only means anything on i386
#ifdef __WIN32__
#define CDECL __cdecl
#else
#define CDECL __attribute__((cdecl))
#endif
#else
#define CDECL
#endif

struct rust_srv {
    void *user;
    void (*log)(rust_srv *, char const *);
    void (*fatal)(rust_srv *, char const *, char const *, size_t);
    void* (*malloc)(rust_srv *, size_t);
    void* (*realloc)(rust_srv *, void*, size_t);
    void (*free)(rust_srv *, void*);
    uintptr_t (*lookup)(rust_srv *, char const *, uint8_t *takes_proc);

    void CDECL (*c_to_proc_glue)(rust_proc*);
};

inline void *operator new(size_t size, rust_srv *srv)
{
    return srv->malloc(srv, size);
}

/*
 * Local Variables:
 * fill-column: 70;
 * indent-tabs-mode: nil
 * c-basic-offset: 4
 * buffer-file-coding-system: utf-8-unix
 * compile-command: "make -k -C .. 2>&1 | sed -e 's/\\/x\\//x:\\//g'";
 * End:
 */

#endif /* RUST_H__ */
