/*
 * Rust runtime library.
 * Copyright 2008, 2009 Graydon Hoare <graydon@pobox.com>.
 * Released under MIT license.
 * See file COPYING for details.
 */

#define __STDC_LIMIT_MACROS 1
#define __STDC_CONSTANT_MACROS 1
#define __STDC_FORMAT_MACROS 1

#include <stdlib.h>
#include <stdint.h>
#include <inttypes.h>

#include <stdio.h>
#include <string.h>

#include "rust.h"
#include "rand.h"
#include "uthash.h"
#include "valgrind.h"

#if defined(__WIN32__)
extern "C" {
#include <windows.h>
#include <wincrypt.h>
}
#elif defined(__GNUC__)
 /*
  * Only for RTLD_DEFAULT, remove _GNU_SOURCE when that dies. We want
  * to be non-GNU-dependent.
  */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <pthread.h>
#else
#error "Platform not supported."
#endif

#define PROC_MAX_UPCALL_ARGS 8
#define I(rt, e) ((e) ? (void)0 :                           \
                  (rt)->srv->fatal(#e, __FILE__, __LINE__))

struct rust_proc;
struct rust_port;
struct rust_chan;
struct rust_rt;

struct rust_str;
struct rust_vec;

static uint32_t const LOG_ALL = 0xffffffff;
static uint32_t const LOG_ERR =        0x1;
static uint32_t const LOG_MEM =        0x2;
static uint32_t const LOG_COMM =       0x4;
static uint32_t const LOG_PROC =       0x8;
static uint32_t const LOG_UPCALL =    0x10;
static uint32_t const LOG_RT =        0x20;
static uint32_t const LOG_ULOG =      0x40;
static uint32_t const LOG_TRACE =     0x80;


static uint32_t
get_logbits()
{
    uint32_t bits = LOG_ULOG|LOG_ERR;
    char *c = getenv("RUST_LOG");
    if (c) {
        bits = 0;
        if (strstr(c, "err"))
            bits |= LOG_ERR;
        if (strstr(c, "mem"))
            bits |= LOG_MEM;
        if (strstr(c, "comm"))
            bits |= LOG_COMM;
        if (strstr(c, "proc"))
            bits |= LOG_PROC;
        if (strstr(c, "up"))
            bits |= LOG_UPCALL;
        if (strstr(c, "rt"))
            bits |= LOG_RT;
        if (strstr(c, "ulog"))
            bits |= LOG_ULOG;
        if (strstr(c, "trace"))
            bits |= LOG_TRACE;
        if (strstr(c, "all"))
            bits = 0xffffffff;
    }
    return bits;
}

/* Proc stack segments. Heap allocated and chained together. */

struct stk_seg {
    struct stk_seg *prev;
    struct stk_seg *next;
    unsigned int valgrind_id;
    uintptr_t prev_fp;
    uintptr_t prev_sp;
    uintptr_t limit;
    uint8_t data[];
};

typedef enum {
    proc_state_running    = 0,
    proc_state_calling_c  = 1,
    proc_state_failing    = 2,
    proc_state_blocked_exited   = 3,
    proc_state_blocked_reading  = 4,
    proc_state_blocked_writing  = 5
} proc_state_t;

static char const * const state_names[] =
    {
        "running",
        "calling_c",
        "exited",
        "blocked_reading",
        "blocked_writing"
    };

typedef enum {
    upcall_code_log_int        = 0,
    upcall_code_log_str        = 1,
    upcall_code_new_proc       = 2,
    upcall_code_del_proc       = 3,
    upcall_code_fail           = 4,
    upcall_code_malloc         = 5,
    upcall_code_free           = 6,
    upcall_code_new_port       = 7,
    upcall_code_del_port       = 8,
    upcall_code_send           = 9,
    upcall_code_recv           = 10,
    upcall_code_new_str        = 11,
    upcall_code_grow_proc      = 12,
    upcall_code_trace_word     = 13,
    upcall_code_trace_str      = 14,
} upcall_t;

typedef enum {
    abi_code_cdecl = 0,
    abi_code_rust = 1
} abi_t;

/* FIXME: change ptr_vec and circ_buf to use flexible-array element
   rather than pointer-to-buf-at-end. */

template <typename T>
class ptr_vec {
    static const size_t INIT_SIZE = 8;

    rust_rt *rt;
    size_t alloc;
    size_t fill;
    T **data;

public:
    ptr_vec(rust_rt *rt);
    ~ptr_vec();

    size_t length() {
        return fill;
    }

    T *& operator[](ssize_t offset) {
        return data[offset];
    }

    void push(T *p);
    T *pop();
    void trim(size_t fill);
    void swapdel(T* p);
};

struct circ_buf {
    static const size_t INIT_CIRC_BUF_UNITS = 8;
    static const size_t MAX_CIRC_BUF_SIZE = 1 << 24;

    rust_rt *rt;
    size_t alloc;
    size_t unit_sz;
    size_t next;
    size_t unread;
    uint8_t *data;

    circ_buf(rust_rt *rt, size_t unit_sz);
    ~circ_buf();
    void operator delete(void *ptr);

    void transfer(void *dst);
    void push(void *src);
    void shift(void *dst);
};


/* Rust types vec and str look identical from our perspective. */

struct rust_vec {
    size_t refcount;
    size_t alloc;
    size_t fill;
    uint8_t data[];
};

struct rust_str {
    size_t refcnt;
    size_t alloc;
    size_t fill;
    uint8_t data[];         /* C99 "flexible array" element. */
};

struct rust_rt {
    rust_rt(rust_srv *srv, size_t &live_allocs);
    ~rust_rt();

    rust_srv *srv;
    size_t &live_allocs;
    uint32_t logbits;
    ptr_vec<rust_proc> running_procs;
    ptr_vec<rust_proc> blocked_procs;
    randctx rctx;
    rust_proc *root_proc;
    rust_port *ports;

    void log(uint32_t logbit, char const *fmt, ...);
    void logptr(char const *msg, uintptr_t ptrval);
    template<typename T>
    void logptr(char const *msg, T* ptrval);
    void *malloc(size_t sz);
    void *calloc(size_t sz);
    void *realloc(void *data, size_t sz);
    void free(void *p);

#ifdef __WIN32__
    void win32_require(LPTSTR fn, BOOL ok);
#endif

    size_t n_live_procs();
    rust_proc *sched();
};

inline void *operator new(size_t sz, rust_rt *rt) {
    return rt->malloc(sz);
}

inline void *operator new[](size_t sz, rust_rt *rt) {
    return rt->malloc(sz);
}

inline void *operator new(size_t sz, rust_rt &rt) {
    return rt.malloc(sz);
}

inline void *operator new[](size_t sz, rust_rt &rt) {
    return rt.malloc(sz);
}

struct global_glue_fns {
    uintptr_t c_to_proc_glue;
    uintptr_t main_exit_proc_glue;
    uintptr_t unwind_glue;
};


struct frame_glue_fns {
    uintptr_t mark_glue;
    uintptr_t drop_glue;
    uintptr_t reloc_glue;
};

/*
 * "Simple" precise, mark-sweep, single-generation GC.
 *
 *  - Every value (transitively) containing to a mutable slot
 *    is a gc_val.
 *
 *  - gc_vals come from the same simple allocator as all other
 *    values but undergo different storage management.
 *
 *  - Every frame has a frame_glue_fns pointer in its fp[-1] slot,
 *    written on function-entry.
 *
 *  - Like gc_vals have *three* extra words at their head, not one.
 *
 *  - A pointer to a gc_val, however, points to the third of these
 *    three words. So a certain quantity of code can treat gc_vals the
 *    same way it would treat refcounted exterior vals.
 *
 *  - The first word at the head of a gc_val is used as a refcount, as
 *    in non-gc allocations.
 *
 *  - The second word at the head of a gc_val is a pointer to a sweep
 *    function, with the low bit of that pointer used as a mark bit.
 *
 *  - The third word at the head of a gc_val is a linked-list pointer
 *    to the gc_val that was allocated (temporally) just before
 *    it. Following this list traces through all the currently active
 *    gc_vals in a proc.
 *
 *  - The proc has a gc_alloc_chain field that points to the most-recent
 *    gc_val allocated.
 *
 *  - GC proceeds as follows:
 *
 *    - The proc calls frame_glue_fns.mark_glue(fp) which marks the
 *      frame and then loops, walking down the frame chain. This marks
 *      all the frames with GC roots (each of those functions in turn
 *      may recursively call into the GC graph, that's for the mark
 *      glue to decide).
 *
 *    - The proc then asks its runtime for its gc_alloc_chain.
 *
 *    - The proc calls
 *
 *        (~1 & gc_alloc_chain[1])(gc_ptr=&gc_alloc_chain)
 *
 *      which sweeps the allocation. Sweeping involves checking to see
 *      if the gc_val at *gc_ptr was marked. If not, it loads
 *      &(*gc_ptr)[2] into tmp, calls drop_ty(*gc_ptr) then
 *      free(*gc_ptr), then gc_ptr=tmp and recurs. If marked, it loads
 *      &(*gc_ptr[2]) into gc_ptr and recurs. The key point is that it
 *      has to call drop_ty, to drop outgoing links into the refcount
 *      graph (and possibly run dtors).
 *
 *    - Note that there is no "special gc state" at work here; the
 *      proc looks like it's running normal code that happens to not
 *      perform any gc_val allocation. Mark-bit twiddling is
 *      open-coded into all the mark functions, which know their
 *      contents; we only have to do O(frames) indirect calls to mark,
 *      the rest are static. Sweeping costs O(gc-heap) indirect calls,
 *      unfortunately, because the set of sweep functions to call is
 *      arbitrary based on allocation order.
 *
 */

struct rust_proc {
    rust_proc(rust_rt *rt,
              rust_proc *spawner,
              uintptr_t exit_proc_glue,
              uintptr_t spawnee_fn,
              size_t callsz);
    ~rust_proc();
    void operator delete(void *ptr);

    rust_rt *rt;
    stk_seg *stk;
    uintptr_t fn;
    uintptr_t runtime_sp;      /* runtime sp while proc running.   */
    uintptr_t rust_sp;         /* saved sp when not running.       */
    proc_state_t state;
    size_t idx;
    size_t refcnt;
    rust_chan *chans;

    uintptr_t gc_alloc_chain;  /* linked list of GC allocations.   */

    /* Parameter space for upcalls. */
    /*
     * FIXME: could probably get away with packing upcall code and
     * state into 1 byte each. And having fewer max upcall args.
     */
    uintptr_t upcall_code;
    uintptr_t upcall_args[PROC_MAX_UPCALL_ARGS];

    uintptr_t get_fp();
    uintptr_t get_previous_fp(uintptr_t fp);
    frame_glue_fns *get_frame_glue_fns(uintptr_t fp);
};

struct rust_port {

    rust_port(rust_proc *proc, size_t unit_sz);
    ~rust_port();

    size_t live_refcnt;
    size_t weak_refcnt;
    rust_proc *proc;
    /* FIXME: 'next' and 'prev' fields are only used for collecting
     * dangling ports on abrupt process termination; can remove this
     * when we have unwinding / finishing working.
     */
    rust_port *next;
    rust_port *prev;
    size_t unit_sz;
    ptr_vec<rust_chan> writers;
    rust_rt *rt;

    void operator delete(void *ptr)
    {
        rust_rt *rt = ((rust_port *)ptr)->rt;
        rt->free(ptr);
    }
};

/*
 * The value held in a rust 'chan' slot is actually a rust_port*,
 * with liveness of the chan indicated by weak_refcnt.
 *
 * Inside each proc, there is a uthash hashtable that maps ports to
 * rust_chan* values, below. The table enforces uniqueness of the
 * channel: one proc has exactly one outgoing channel (buffer) for
 * each port.
 */

struct rust_chan {

    rust_chan(rust_port *port);
    ~rust_chan();
    void operator delete(void *ptr);

    UT_hash_handle hh;
    rust_port *port;
    uintptr_t queued;     /* Whether we're in a port->writers vec. */
    size_t idx;           /* Index in the port->writers vec. */
    rust_proc *blocked; /* Proc to wake on flush,
                             NULL if nonblocking. */
    circ_buf buf;
};

/* Utility type: pointer-vector. */

template <typename T>
ptr_vec<T>::ptr_vec(rust_rt *rt) :
    rt(rt),
    alloc(INIT_SIZE),
    fill(0),
    data(new (rt) T*[alloc])
{
    I(rt, data);
    rt->log(LOG_MEM,
            "new ptr_vec(data=0x%" PRIxPTR ") -> ptr_vec==0x%" PRIxPTR,
            (uintptr_t)data, (uintptr_t)this);
}

template <typename T>
ptr_vec<T>::~ptr_vec()
{
    I(rt, data);
    rt->log(LOG_MEM,
            "~ptr_vec 0x%" PRIxPTR ", data=0x%" PRIxPTR,
            (uintptr_t)this, (uintptr_t)data);
    I(rt, fill == 0);
    rt->free(data);
}

template <typename T>
void
ptr_vec<T>::push(T *p)
{
    I(rt, data);
    if (fill == alloc) {
        alloc *= 2;
        data = (T **)rt->realloc(data, alloc);
    }
    I(rt, fill < alloc);
    p->idx = fill;
    data[fill++] = p;
}

template <typename T>
T *
ptr_vec<T>::pop()
{
    return data[--fill];
}

template <typename T>
void
ptr_vec<T>::trim(size_t sz)
{
    I(rt, data);
    if (sz <= (alloc / 4) &&
        (alloc / 2) >= INIT_SIZE) {
        alloc /= 2;
        I(rt, alloc >= fill);
        data = (T **)rt->realloc(data, alloc);
        I(rt, data);
    }
}

template <typename T>
void
ptr_vec<T>::swapdel(T *item)
{
    /* Swap the endpoint into i and decr fill. */
    I(rt, data);
    I(rt, fill > 0);
    I(rt, item->idx < fill);
    fill--;
    if (fill > 0) {
        T *subst = data[fill];
        size_t idx = item->idx;
        data[idx] = subst;
        subst->idx = idx;
    }
}

/* Utility type: circular buffer. */

circ_buf::circ_buf(rust_rt *rt, size_t unit_sz) :
    rt(rt),
    alloc(INIT_CIRC_BUF_UNITS * unit_sz),
    unit_sz(unit_sz),
    next(0),
    unread(0),
    data((uint8_t *)rt->calloc(alloc))
{
    I(rt, unit_sz);
    rt->log(LOG_MEM|LOG_COMM,
            "new circ_buf(alloc=%d, unread=%d) -> circ_buf=0x%" PRIxPTR,
            alloc, unread, this);
    I(rt, data);
}

circ_buf::~circ_buf()
{
    rt->log(LOG_MEM|LOG_COMM,
            "~circ_buf 0x%" PRIxPTR,
            this);
    I(rt, data);
    I(rt, unread == 0);
    rt->free(data);
}

void
circ_buf::operator delete(void *ptr)
{
    rust_rt *rt = ((circ_buf *)ptr)->rt;
    rt->free(ptr);
}

void
circ_buf::transfer(void *dst)
{
    size_t i;
    uint8_t *d = (uint8_t *)dst;
    I(rt, dst);
    for (i = 0; i < unread; i += unit_sz)
        memcpy(&d[i], &data[next + i % alloc], unit_sz);
}

void
circ_buf::push(void *src)
{
    size_t i;
    void *tmp;

    I(rt, src);
    I(rt, unread <= alloc);

    /* Grow if necessary. */
    if (unread == alloc) {
        I(rt, alloc <= MAX_CIRC_BUF_SIZE);
        tmp = rt->malloc(alloc << 1);
        transfer(tmp);
        alloc <<= 1;
        rt->free(data);
        data = (uint8_t *)tmp;
    }

    rt->log(LOG_MEM|LOG_COMM,
            "circ buf push, unread=%d, alloc=%d, unit_sz=%d",
            unread, alloc, unit_sz);

    I(rt, unread < alloc);
    I(rt, unread + unit_sz <= alloc);

    i = (next + unread) % alloc;
    memcpy(&data[i], src, unit_sz);

    rt->log(LOG_MEM|LOG_COMM, "pushed data at index %d", i);
    unread += unit_sz;
}

void
circ_buf::shift(void *dst)
{
    size_t i;
    void *tmp;

    I(rt, dst);
    I(rt, unit_sz > 0);
    I(rt, unread >= unit_sz);
    I(rt, unread <= alloc);
    I(rt, data);
    i = next;
    memcpy(dst, &data[i], unit_sz);
    rt->log(LOG_MEM|LOG_COMM, "shifted data from index %d", i);
    unread -= unit_sz;
    next += unit_sz;
    I(rt, next <= alloc);
    if (next == alloc)
        next = 0;

    /* Shrink if necessary. */
    if (alloc >= INIT_CIRC_BUF_UNITS * unit_sz &&
        unread <= alloc / 4) {
        tmp = rt->malloc(alloc / 2);
        transfer(tmp);
        alloc >>= 1;
        rt->free(data);
        data = (uint8_t *)tmp;
    }
}

/* Ports */

rust_port::rust_port(rust_proc *proc, size_t unit_sz)
    : live_refcnt(0),
      weak_refcnt(0),
      proc(proc),
      next(NULL),
      prev(NULL),
      unit_sz(unit_sz),
      writers(proc->rt),
      rt(proc->rt)
{
    rt->log(LOG_MEM|LOG_COMM,
            "new rust_port(proc=0x%" PRIxPTR ", unit_sz=%d) -> port=0x%"
            PRIxPTR, (uintptr_t)proc, unit_sz, (uintptr_t)this);
    if (rt->ports)
        rt->ports->prev = this;
    next = rt->ports;
    rt->ports = this;
}

rust_port::~rust_port()
{
    rt->log(LOG_COMM|LOG_MEM,
            "~rust_port 0x%" PRIxPTR,
            (uintptr_t)this);
    /* FIXME: need to force-fail all the queued writers. */
    for (size_t i = 0; i < writers.length(); ++i)
        delete writers[i];
    /* FIXME: can remove the chaining-of-ports-to-rt when we have
     * unwinding / finishing working. */
    if (prev)
        prev->next = next;
    else if (this == rt->ports)
        rt->ports = next;
    if (next)
        next->prev = prev;
}

/* Channels */

rust_chan::rust_chan(rust_port *port)
    : port(port),
      queued(0),
      idx(0),
      blocked(NULL),
      buf(port->proc->rt, port->unit_sz)
{
    rust_rt *rt = port->proc->rt;
    rt->log(LOG_MEM|LOG_COMM,
            "new rust_chan(port=0x%" PRIxPTR ") -> chan=0x%" PRIxPTR,
            port, (uintptr_t)this);
}

rust_chan::~rust_chan()
{
    rust_rt *rt = port->proc->rt;
    rt->log(LOG_MEM|LOG_COMM,
            "~rust_chan 0x%" PRIxPTR, (uintptr_t)this);
}

void
rust_chan::operator delete(void *ptr)
{
    rust_rt *rt = ((rust_chan *)ptr)->port->proc->rt;
    rt->free(ptr);
}


/* Stacks */

static size_t const min_stk_bytes = 0x300;

static stk_seg*
new_stk(rust_rt *rt, size_t minsz)
{
    if (minsz < min_stk_bytes)
        minsz = min_stk_bytes;
    size_t sz = sizeof(stk_seg) + minsz;
    stk_seg *stk = (stk_seg *)rt->malloc(sz);
    rt->logptr("new stk", (uintptr_t)stk);
    memset(stk, 0, sizeof(stk_seg));
    stk->limit = (uintptr_t) &stk->data[minsz];
    rt->logptr("stk limit", stk->limit);
    stk->valgrind_id =
        VALGRIND_STACK_REGISTER(&stk->data[0],
                                &stk->data[minsz]);
    return stk;
}

static void
del_stk(rust_rt *rt, stk_seg *stk)
{
    stk_seg *nxt = 0;

    /* Rewind to bottom-most stk segment. */
    while (stk->prev)
        stk = stk->prev;

    /* Then free forwards. */
    do {
        nxt = stk->next;
        rt->logptr("freeing stk segment", (uintptr_t)stk);
        VALGRIND_STACK_DEREGISTER(stk->valgrind_id);
        rt->free(stk);
        stk = nxt;
    } while (stk);
    rt->log(LOG_MEM, "freed stacks");
}

/* Processes */

/* FIXME: ifdef by platform. This is getting absurdly x86-specific. */
size_t const n_callee_saves = 4;
size_t const callee_save_fp = 0;

static void
upcall_grow_proc(rust_proc *proc, size_t n_call_bytes, size_t n_frame_bytes)
{
    /*
     *  We have a stack like this:
     *
     *  | higher frame  |
     *  +---------------+ <-- top of call region
     *  | caller args   |
     *  | ...           |
     *  | ABI operands  |   <-- top of fixed-size call region
     *  | ...           |
     *  | retpc         |
     *  | callee save 1 |
     *  | ...           |
     *  | callee save N |
     *  +---------------+ <-- fp, base of call region
     *  |               |
     *
     * And we were hoping to move fp down by n_frame_bytes to allocate
     * an n_frame_bytes frame for the current function, but we ran out
     * of stack. So rather than subtract fp, we called into this
     * function.
     *
     * This function's job is:
     *
     *  - Check to see if we have an existing stack segment chained on
     *    the end of the stack chain. If so, check to see that it's
     *    big enough for K. If not, or if we lack an existing stack
     *    segment altogether, allocate a new one of size K and chain
     *    it into the stack segments list for this proc.
     *
     *  - Transition to the new segment. This means memcopying the
     *    call region [fp, fp+n_call_bytes) into the new segment and
     *    adjusting the process' fp to point to the new base of the
     *    (transplanted) call region.
     *
     *
     *  K = max(min_stk_bytes, n_call_bytes + n_frame_bytes)
     *
     *  n_call_bytes = (arg_sz + abi_frame_base_sz)
     *
     *  n_frame_bytes = (new_frame_sz +
     *                   new_spill_sz +
     *                   new_call_sz +
     *                   abi_frame_base_sz +
     *                   proco_c_glue_sz)
     *
     *  proco_c_glue_sz = abi_frame_base_sz
     *
     * Note: there's a lot of stuff in K! You have to reserve enough
     * space for the new frame, enough space for the transplanted call,
     * enough space to *make* an outgoing call out of the new frame,
     * and enough space to perform a proc-to-C glue call to get back to
     * this function when you find you're out of stack again, mid-call.
     *
     */
    rust_rt *rt = proc->rt;
    stk_seg *nstk = proc->stk->next;
    if (nstk) {
        /* Figure out if the existing chunk is big enough. */
        size_t sz = nstk->limit - ((uintptr_t) &proc->stk->data[0]);
        if (sz < n_frame_bytes) {
            nstk = new_stk(rt, n_frame_bytes);
            nstk->next = proc->stk->next;
            nstk->next->prev = nstk;
        }
    } else {
        /* There is no existing next stack segment, grow. */
        nstk = new_stk(rt, n_frame_bytes);
    }
    I(rt, nstk);
    proc->stk->next = nstk;
    nstk->prev = proc->stk;
    /*
    uintptr_t i;
    for (i = proc->sp + n_call_bytes; i >= proc->sp; i -= sizeof(uintptr_t)) {
        uintptr_t val = *((uintptr_t*)i);
        printf("stk[0x%" PRIxPTR "] = 0x%" PRIxPTR "\n", i, val);
    }
    printf("transplant: n_call_bytes %d, n_frame_bytes %d\n", n_call_bytes, n_frame_bytes);
    */
    uintptr_t target = nstk->limit - n_call_bytes;
    memcpy((void*)target, (void*)proc->rust_sp, n_call_bytes);
    proc->stk = nstk;
    proc->rust_sp = target;
}

rust_proc::rust_proc(rust_rt *rt,
                     rust_proc *spawner,
                     uintptr_t exit_proc_glue,
                     uintptr_t spawnee_fn,
                     size_t callsz)
    :
      rt(rt),
      stk(new_stk(rt, 0)),
      fn(spawnee_fn),
      runtime_sp(0),
      rust_sp(stk->limit),
      state(proc_state_running),
      idx(0),
      refcnt(1),
      chans(NULL),
      gc_alloc_chain(0),
      upcall_code(0)
{
    rt->logptr("new proc", (uintptr_t)this);
    rt->logptr("exit-proc glue", exit_proc_glue);
    rt->logptr("from spawnee", spawnee_fn);

    // Set sp to last uintptr_t-sized cell of segment
    // then align down to 16 boundary, to be safe-ish for
    // alignment (?)
    //
    // FIXME: actually convey alignment constraint here so
    // we're not just being conservative. I don't *think*
    // there are any platforms alive at the moment with
    // >16 byte alignment constraints, but this is sloppy.

    rust_sp -= sizeof(uintptr_t);
    rust_sp &= ~0xf;

    // Begin synthesizing frames. There are two: a "fully formed"
    // exit-proc frame at the top of the stack -- that pretends to be
    // mid-execution -- and a just-starting frame beneath it that
    // starts executing the first instruction of the spawnee. The
    // spawnee *thinks* it was called by the exit-proc frame above
    // it. It wasn't; we put that fake frame in place here, but the
    // illusion is enough for the spawnee to return to the exit-proc
    // frame when it's done, and exit.
    uintptr_t *spp = (uintptr_t *)rust_sp;

    // The exit_proc_glue frame we synthesize above the frame we activate:
    *spp-- = (uintptr_t) this;       // proc
    *spp-- = (uintptr_t) 0;          // output
    *spp-- = (uintptr_t) 0;          // retpc
    for (size_t j = 0; j < n_callee_saves; ++j) {
        *spp-- = 0;
    }

    // We want 'frame_base' to point to the last callee-save in this
    // (exit-proc) frame, because we're going to inject this
    // frame-pointer into the callee-save frame pointer value in the
    // *next* (spawnee) frame. A cheap trick, but this means the
    // spawnee frame will restore the proper frame pointer of the glue
    // frame as it runs its epilogue.
    uintptr_t frame_base = (uintptr_t) (spp+1);

    *spp-- = (uintptr_t) 0;          // frame_glue_fns

    // Copy args from spawner to spawnee.
    if (spawner)  {
        uintptr_t *src = (uintptr_t*) spawner->rust_sp;
        src += 1;                  // was at upcall-retpc
        src += n_callee_saves;     // proc_to_c_glue-saves
        src += 1;                  // spawn-call output slot
        src += 1;                  // spawn-call proc slot
        // Memcpy all but the proc and output pointers
        callsz -= (2 * sizeof(uintptr_t));
        spp = (uintptr_t*) (((uintptr_t)spp) - callsz);
        memcpy(spp, src, callsz);

        // Move sp down to point to proc cell.
        spp--;
    } else {
        // We're at root, starting up.
        I(rt, callsz==0);
    }

    // The *implicit* incoming args to the spawnee frame we're activating:
    // FIXME: wire up output-address properly so spawnee can write a return
    // value.
    *spp-- = (uintptr_t) this;            // proc
    *spp-- = (uintptr_t) 0;               // output addr
    *spp-- = (uintptr_t) exit_proc_glue;  // retpc

    // The context the c_to_proc_glue needs to switch stack.
    *spp-- = (uintptr_t) spawnee_fn;      // instruction to start at
    for (size_t j = 0; j < n_callee_saves; ++j) {
        // callee-saves to carry in when we activate
        if (j == callee_save_fp)
            *spp-- = frame_base;
        else
            *spp-- = NULL;
    }

    // Back up one, we overshot where sp should be.
    rust_sp = (uintptr_t) (spp+1);
}


rust_proc::~rust_proc()
{
    rt->log(LOG_MEM|LOG_PROC,
            "~rust_proc 0x%" PRIxPTR ", refcnt=%d",
            (uintptr_t)this, refcnt);

    for (uintptr_t fp = get_fp(); fp; fp = get_previous_fp(fp)) {
        frame_glue_fns *glue_fns = get_frame_glue_fns(fp);
        rt->log(LOG_MEM|LOG_PROC,
                "~rust_proc, frame fp=0x%" PRIxPTR ", glue_fns=0x%" PRIxPTR,
                fp, glue_fns);
        if (glue_fns) {
            rt->log(LOG_MEM|LOG_PROC, "~rust_proc, mark_glue=0x%" PRIxPTR, glue_fns->mark_glue);
            rt->log(LOG_MEM|LOG_PROC, "~rust_proc, drop_glue=0x%" PRIxPTR, glue_fns->drop_glue);
            rt->log(LOG_MEM|LOG_PROC, "~rust_proc, reloc_glue=0x%" PRIxPTR, glue_fns->reloc_glue);
        }
    }

    /* FIXME: tighten this up, there are some more
       assertions that hold at proc-lifecycle events. */
    I(rt, refcnt == 0 ||
      (refcnt == 1 && this == rt->root_proc));

    del_stk(rt, stk);

    while (chans) {
        rust_chan *c = chans;
        HASH_DEL(chans, c);
        delete c;
    }
}


void
rust_proc::operator delete(void *ptr)
{
    rust_rt *rt = ((rust_proc *)ptr)->rt;
    rt->free(ptr);
}

static inline uintptr_t
get_callee_save_fp(uintptr_t *top_of_callee_saves)
{
    return top_of_callee_saves[n_callee_saves - (callee_save_fp + 1)];
}

uintptr_t
rust_proc::get_fp() {
    // sp in any suspended proc points to the last callee-saved reg on
    // the proc stack.
    return get_callee_save_fp((uintptr_t*)rust_sp);
}

uintptr_t
rust_proc::get_previous_fp(uintptr_t fp) {
    // fp happens to, coincidentally (!) also point to the last
    // callee-save on the proc stack.
    return get_callee_save_fp((uintptr_t*)fp);
}

frame_glue_fns*
rust_proc::get_frame_glue_fns(uintptr_t fp) {
    fp -= sizeof(uintptr_t);
    return *((frame_glue_fns**) fp);
}

static ptr_vec<rust_proc>*
get_state_vec(rust_rt *rt, proc_state_t state)
{
    switch (state) {
    case proc_state_running:
    case proc_state_calling_c:
    case proc_state_failing:
        return &rt->running_procs;

    case proc_state_blocked_exited:
    case proc_state_blocked_reading:
    case proc_state_blocked_writing:
        return &rt->blocked_procs;
    }
    I(rt, 0);
    return NULL;
}

static ptr_vec<rust_proc>*
get_proc_vec(rust_rt *rt, rust_proc *proc)
{
    return get_state_vec(rt, proc->state);
}

static void
add_proc_state_vec(rust_rt *rt, rust_proc *proc)
{
    ptr_vec<rust_proc> *v = get_proc_vec(rt, proc);
    rt->log(LOG_MEM|LOG_PROC,
            "adding proc 0x%" PRIxPTR " in state '%s' to vec 0x%" PRIxPTR,
            (uintptr_t)proc, state_names[(size_t)proc->state], (uintptr_t)v);
    v->push(proc);
}


static void
remove_proc_from_state_vec(rust_rt *rt, rust_proc *proc)
{
    ptr_vec<rust_proc> *v = get_proc_vec(rt, proc);
    rt->log(LOG_MEM|LOG_PROC,
            "removing proc 0x%" PRIxPTR " in state '%s' from vec 0x%" PRIxPTR,
            (uintptr_t)proc, state_names[(size_t)proc->state], (uintptr_t)v);
    I(rt, (*v)[proc->idx] == proc);
    v->swapdel(proc);
    v->trim(rt->n_live_procs());
}

static void
proc_state_transition(rust_rt *rt,
                      rust_proc *proc,
                      proc_state_t src,
                      proc_state_t dst)
{
    rt->log(LOG_PROC,
            "proc 0x%" PRIxPTR " state change '%s' -> '%s'",
            (uintptr_t)proc,
            state_names[(size_t)src],
            state_names[(size_t)dst]);
    I(rt, proc->state == src);
    remove_proc_from_state_vec(rt, proc);
    proc->state = dst;
    add_proc_state_vec(rt, proc);
}

extern "C" CDECL void
fail_proc(rust_rt *rt, rust_proc *proc)
{
    rt->log(LOG_PROC,
            "fail_proc(0x%" PRIxPTR "), refcnt=%d",
            proc, proc->refcnt);
    I(rt, rt->n_live_procs() > 0);
    proc_state_transition(rt, proc,
                          proc->state,
                          proc_state_failing);
}

extern "C" CDECL void
upcall_del_proc(rust_proc *proc)
{
    rust_rt *rt = proc->rt;
    rt->log(LOG_UPCALL,
            "upcall del_proc(0x%" PRIxPTR "), refcnt=%d",
            proc, proc->refcnt);
    fail_proc(rt, proc);

    // FIXME: remove this part.
    remove_proc_from_state_vec(rt, proc);
    delete proc;
}

/* Runtime */

static void
del_all_procs(rust_rt *rt, ptr_vec<rust_proc> *v) {
    I(rt, v);
    while (v->length()) {
        rt->log(LOG_PROC, "deleting live proc %" PRIdPTR, v->length() - 1);
        delete v->pop();
    }
}

rust_rt::rust_rt(rust_srv *srv, size_t &live_allocs) :
    srv(srv),
    live_allocs(live_allocs),
    logbits(get_logbits()),
    running_procs(this),
    blocked_procs(this),
    root_proc(NULL),
    ports(NULL)
{
    logptr("new rt", (uintptr_t)this);
    memset(&rctx, 0, sizeof(rctx));

#ifdef __WIN32__
    {
        HCRYPTPROV hProv;
        win32_require
            ("CryptAcquireContext",
             CryptAcquireContext(&hProv, NULL, NULL, PROV_DSS,
                                 CRYPT_VERIFYCONTEXT|CRYPT_SILENT));
        win32_require
            ("CryptGenRandom",
             CryptGenRandom(hProv, sizeof(rctx.randrsl),
                            (BYTE*)(&rctx.randrsl)));
        win32_require
            ("CryptReleaseContext",
             CryptReleaseContext(hProv, 0));
    }
#else
    int fd = open("/dev/urandom", O_RDONLY);
    I(this, fd > 0);
    I(this, read(fd, (void*) &rctx.randrsl, sizeof(rctx.randrsl))
      == sizeof(rctx.randrsl));
    I(this, close(fd) == 0);
#endif
    randinit(&rctx, 1);
}

rust_rt::~rust_rt() {
    log(LOG_PROC, "deleting all running procs");
    del_all_procs(this, &running_procs);
    log(LOG_PROC, "deleting all blocked procs");
    del_all_procs(this, &blocked_procs);

    log(LOG_PROC, "deleting all dangling ports");
    /* FIXME: remove when port <-> proc linkage is obsolete. */
    while (ports)
        delete ports;
}

void
rust_rt::log(uint32_t logbit, char const *fmt, ...) {
    char buf[256];
    if (logbits & logbit) {
        va_list args;
        va_start(args, fmt);
        vsnprintf(buf, sizeof(buf), fmt, args);
        srv->log(buf);
        va_end(args);
    }
}

void
rust_rt::logptr(char const *msg, uintptr_t ptrval) {
    log(LOG_MEM, "%s 0x%" PRIxPTR, msg, ptrval);
}

template<typename T> void
rust_rt::logptr(char const *msg, T* ptrval) {
    log(LOG_MEM, "%s 0x%" PRIxPTR, msg, (uintptr_t)ptrval);
}

void *
rust_rt::malloc(size_t sz) {
    void *p = srv->malloc(sz);
    I(this, p);
    live_allocs++;
    log(LOG_MEM, "rust_rt::malloc(%d) -> 0x%" PRIxPTR,
        sz, p);
    return p;
}

void *
rust_rt::calloc(size_t sz) {
    void *p = this->malloc(sz);
    memset(p, 0, sz);
    return p;
}

void *
rust_rt::realloc(void *p, size_t sz) {
    void *p1 = srv->realloc(p, sz);
    I(this, p1);
    if (!p)
        live_allocs++;
    log(LOG_MEM, "rust_rt::realloc(0x%" PRIxPTR ", %d) -> 0x%" PRIxPTR,
        p, sz, p1);
    return p1;
}

void
rust_rt::free(void *p) {
    log(LOG_MEM, "rust_rt::free(0x%" PRIxPTR ")", p);
    I(this, p);
    srv->free(p);
    I(this, live_allocs > 0);
    live_allocs--;
}

#ifdef __WIN32__
void
rust_rt::win32_require(LPTSTR fn, BOOL ok) {
    if (!ok) {
        LPTSTR buf;
        DWORD err = GetLastError();
        FormatMessage(FORMAT_MESSAGE_ALLOCATE_BUFFER |
                      FORMAT_MESSAGE_FROM_SYSTEM |
                      FORMAT_MESSAGE_IGNORE_INSERTS,
                      NULL, err,
                      MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
                      (LPTSTR) &buf, 0, NULL );
        log(LOG_ERR, "%s failed with error %ld: %s", fn, err, buf);
        LocalFree((HLOCAL)buf);
        I(this, ok);
    }
}
#endif

size_t
rust_rt::n_live_procs()
{
    return running_procs.length() + blocked_procs.length();
}

rust_proc *
rust_rt::sched()
{
    I(this, this);
    I(this, n_live_procs() > 0);
    if (running_procs.length() > 0) {
        size_t i = rand(&rctx);
        i %= running_procs.length();
        return (rust_proc *)running_procs[i];
    }
    log(LOG_RT|LOG_PROC,
        "no schedulable processes");
    return NULL;
}

/* Upcalls */

extern "C" CDECL char const *str_buf(rust_proc *proc, rust_str *s);

extern "C" CDECL void
upcall_log_int(rust_proc *proc, int32_t i)
{
    rust_rt *rt = proc->rt;
    rt->log(LOG_UPCALL|LOG_ULOG,
            "upcall log_int(0x%" PRIx32 " = %" PRId32 " = '%c')",
            i, i, (char)i);
}

extern "C" CDECL void
upcall_log_str(rust_proc *proc, rust_str *str)
{
    rust_rt *rt = proc->rt;
    const char *c = str_buf(proc, str);
    rt->log(LOG_UPCALL|LOG_ULOG,
            "upcall log_str(\"%s\")",
            c);
}

extern "C" CDECL void
upcall_trace_word(rust_proc *proc, uintptr_t i)
{
    rust_rt *rt = proc->rt;
    rt->log(LOG_UPCALL|LOG_TRACE,
            "trace: 0x%" PRIxPTR "",
            i, i, (char)i);
}

extern "C" CDECL void
upcall_trace_str(rust_proc *proc, char const *c)
{
    rust_rt *rt = proc->rt;
    rt->log(LOG_UPCALL|LOG_TRACE,
            "trace: %s",
            c);
}

extern "C" CDECL rust_port*
upcall_new_port(rust_proc *proc, size_t unit_sz)
{
    rust_rt *rt = proc->rt;
    rt->log(LOG_UPCALL|LOG_MEM|LOG_COMM,
            "upcall_new_port(proc=0x%" PRIxPTR ", unit_sz=%d)",
            (uintptr_t)proc, unit_sz);
    rust_port *port = new (rt) rust_port(proc, unit_sz);
    port->live_refcnt = 1;
    return port;
}

extern "C" CDECL void
upcall_del_port(rust_proc *proc, rust_port *port)
{
    rust_rt *rt = proc->rt;
    rt->log(LOG_UPCALL|LOG_MEM|LOG_COMM,
            "upcall del_port(0x%" PRIxPTR "), live refcnt=%d, weak refcnt=%d",
            (uintptr_t)port, port->live_refcnt, port->weak_refcnt);

    I(rt, port->live_refcnt == 0 || port->weak_refcnt == 0);

    if (port->live_refcnt == 0 &&
        port->weak_refcnt == 0) {
        delete port;
    }
}

/*
 * Buffering protocol:
 *
 *   - Reader attempts to read:
 *     - Set reader to blocked-reading state.
 *     - If buf with data exists:
 *       - Attempt transmission.
 *
 *  - Writer attempts to write:
 *     - Set writer to blocked-writing state.
 *     - Copy data into chan.
 *     - Attempt transmission.
 *
 *  - Transmission:
 *       - Copy data from buf to reader
 *       - Decr buf
 *       - Set reader to running
 *       - If buf now empty and blocked writer:
 *         - Set blocked writer to running
 *
 */

static int
attempt_transmission(rust_rt *rt,
                     rust_chan *src,
                     rust_proc *dst)
{
    I(rt, src);
    I(rt, dst);

    if (dst->state != proc_state_blocked_reading) {
        rt->log(LOG_COMM,
                "dst in non-reading state, "
                "transmission incomplete");
        return 0;
    }

    if (src->blocked) {
        I(rt, src->blocked->state == proc_state_blocked_writing);
    }

    if (src->buf.unread == 0) {
        rt->log(LOG_COMM,
                "buffer empty, "
                "transmission incomplete");
        return 0;
    }

    uintptr_t *dptr = (uintptr_t*)dst->upcall_args[0];
    src->buf.shift(dptr);

    if (src->blocked) {
        proc_state_transition(rt, src->blocked,
                              proc_state_blocked_writing,
                              proc_state_running);
        src->blocked = NULL;
    }

    proc_state_transition(rt, dst,
                          proc_state_blocked_reading,
                          proc_state_running);

    rt->log(LOG_COMM, "transmission complete");
    return 1;
}

extern "C" CDECL void
upcall_send(rust_proc *src, rust_port *port, void *sptr)
{
    rust_rt *rt = src->rt;
    rt->log(LOG_UPCALL|LOG_COMM,
            "upcall send(proc=0x%" PRIxPTR ", port=0x%" PRIxPTR ")",
            (uintptr_t)src,
            (uintptr_t)port);

    rust_chan *chan = NULL;

    if (!port) {
        rt->log(LOG_COMM|LOG_ERR,
                "send to NULL port (possibly throw?)");
        return;
    }

    rt->log(LOG_MEM|LOG_COMM,
            "send to port", (uintptr_t)port);

    I(rt, src);
    I(rt, port);
    I(rt, sptr);
    HASH_FIND(hh, src->chans, port, sizeof(rust_port*), chan);
    if (!chan) {
        chan = new (rt) rust_chan(port);
        HASH_ADD(hh, src->chans, port, sizeof(rust_port*), chan);
    }
    I(rt, chan);
    I(rt, chan->blocked == src || !chan->blocked);
    I(rt, chan->port);
    I(rt, chan->port == port);

    rt->log(LOG_MEM|LOG_COMM,
            "sending via chan 0x%" PRIxPTR,
            (uintptr_t)chan);

    if (port->proc) {
        chan->blocked = src;
        chan->buf.push(sptr);
        proc_state_transition(rt, src,
                              proc_state_calling_c,
                              proc_state_blocked_writing);
        attempt_transmission(rt, chan, port->proc);
        if (chan->buf.unread && !chan->queued) {
            chan->queued = 1;
            port->writers.push(chan);
        }
    } else {
        rt->log(LOG_COMM|LOG_ERR,
                "port has no proc (possibly throw?)");
    }
}

extern "C" CDECL void
upcall_recv(rust_proc *dst, rust_port *port)
{
    rust_rt *rt = dst->rt;
    rt->log(LOG_UPCALL|LOG_COMM,
            "upcall recv(proc=0x%" PRIxPTR ", port=0x%" PRIxPTR ")",
            (uintptr_t)dst,
            (uintptr_t)port);

    I(rt, port);
    I(rt, port->proc);
    I(rt, dst);
    I(rt, port->proc == dst);

    proc_state_transition(rt, dst,
                          proc_state_calling_c,
                          proc_state_blocked_reading);

    if (port->writers.length() > 0) {
        I(rt, dst->rt);
        size_t i = rand(&dst->rt->rctx);
        i %= port->writers.length();
        rust_chan *schan = port->writers[i];
        I(rt, schan->idx == i);
        if (attempt_transmission(rt, schan, dst)) {
            port->writers.swapdel(schan);
            port->writers.trim(port->writers.length());
            schan->queued = 0;
        }
    } else {
        rt->log(LOG_COMM,
                "no writers sending to port", (uintptr_t)port);
    }
}

extern "C" CDECL void
upcall_fail(rust_proc *proc, char const *expr, char const *file, size_t line)
{
    rust_rt *rt =proc->rt;
    /* FIXME: throw, don't just exit. */
    rt->log(LOG_UPCALL, "upcall fail '%s', %s:%" PRIdPTR,
            expr, file, line);
    rt->srv->fatal(expr, file, line);
    fail_proc(rt, proc);
}

extern "C" CDECL uintptr_t
upcall_malloc(rust_proc *proc, size_t nbytes)
{
    rust_rt *rt = proc->rt;
    void *p = rt->malloc(nbytes);
    rt->log(LOG_UPCALL|LOG_MEM,
            "upcall malloc(%u) = 0x%" PRIxPTR,
            nbytes, (uintptr_t)p);
    return (uintptr_t) p;
}

extern "C" CDECL void
upcall_free(rust_proc *proc, void* ptr)
{
    rust_rt *rt = proc->rt;
    rt->log(LOG_UPCALL|LOG_MEM,
            "upcall free(0x%" PRIxPTR ")",
            (uintptr_t)ptr);
    rt->free(ptr);
}

static size_t
next_power_of_two(size_t s)
{
    size_t tmp = s - 1;
    tmp |= tmp >> 1;
    tmp |= tmp >> 2;
    tmp |= tmp >> 4;
    tmp |= tmp >> 8;
    tmp |= tmp >> 16;
#if SIZE_MAX == UINT64_MAX
    tmp |= tmp >> 32;
#endif
    return tmp + 1;
}


extern "C" CDECL rust_str*
upcall_new_str(rust_proc *proc, char const *s, size_t fill)
{
    rust_rt *rt = proc->rt;
    size_t alloc = next_power_of_two(fill);
    rust_str *st = (rust_str*) rt->malloc(sizeof(rust_str) + alloc);
    st->refcnt = 1;
    st->fill = fill;
    st->alloc = alloc;
    if (s)
        memcpy(&st->data[0], s, fill);
    rt->log(LOG_UPCALL|LOG_MEM,
            "upcall new_str('%s', %" PRIdPTR ") -> 0x%" PRIxPTR,
            s, fill, st);
    return st;
}


static void
rust_main_loop(uintptr_t main_fn, uintptr_t main_exit_proc_glue, rust_srv *srv);

struct rust_ticket {
    uintptr_t main_fn;
    uintptr_t main_exit_proc_glue;
    rust_srv *srv;

    explicit rust_ticket(uintptr_t main_fn,
                         uintptr_t main_exit_proc_glue,
                         rust_srv *srv)
        : main_fn(main_fn),
          main_exit_proc_glue(main_exit_proc_glue),
          srv(srv)
    {}

    ~rust_ticket()
    {}

    void operator delete(void *ptr)
    {
        rust_srv *srv = ((rust_ticket *)ptr)->srv;
        srv->free(ptr);
    }
};

#if defined(__WIN32__)
static DWORD WINAPI rust_thread_start(void *ptr)
#elif defined(__GNUC__)
static void *rust_thread_start(void *ptr)
#else
#error "Platform not supported"
#endif
{
    /*
     * The thread that spawn us handed us a ticket. Read the ticket's content
     * and then deallocate it. Since thread creation is asynchronous, the other
     * thread can't do this for us.
     */
    rust_ticket *ticket = (rust_ticket *)ptr;
    uintptr_t main_fn = ticket->main_fn;
    uintptr_t main_exit_proc_glue = ticket->main_exit_proc_glue;
    rust_srv *srv = ticket->srv;
    delete ticket;

    /*
     * Start a new rust main loop for this thread.
     */
    rust_main_loop(main_fn, main_exit_proc_glue, srv);

    return 0;
}

extern "C" CDECL rust_proc*
upcall_new_proc(rust_proc *spawner, uintptr_t exit_proc_glue,
                uintptr_t spawnee_fn, size_t callsz)
{
    rust_rt *rt = spawner->rt;
    rt->log(LOG_UPCALL|LOG_MEM|LOG_PROC,
         "spawn fn: exit_proc_glue 0x%" PRIxPTR ", spawnee 0x%" PRIxPTR ", callsz %d",
         exit_proc_glue, spawnee_fn, callsz);
    rust_proc *proc = new (rt) rust_proc(rt, spawner, exit_proc_glue, spawnee_fn, callsz);
    add_proc_state_vec(rt, proc);
    return proc;
}

extern "C" CDECL rust_proc *
upcall_new_thread(rust_proc *spawner, uintptr_t exit_proc_glue, uintptr_t spawnee_fn)
{
    rust_rt *rt = spawner->rt;
    rust_srv *srv = rt->srv;
    /*
     * The ticket is not bound to the current runtime, so allocate directly from the
     * service.
     */
    rust_ticket *ticket = new (srv) rust_ticket(spawnee_fn, exit_proc_glue, srv);

#if defined(__WIN32__)
    DWORD thread;
    CreateThread(NULL, 0, rust_thread_start, (void *)ticket, 0, &thread);
#elif defined(__GNUC__)
    pthread_t thread;
    pthread_create(&thread, NULL, rust_thread_start, (void *)ticket);
#else
#error "Platform not supported"
#endif

    /*
     * Create a proxy proc that will represent the newly created thread in this runtime.
     * All communication will go through this proxy proc.
     */
    return NULL;
}

static void
handle_upcall(rust_proc *proc)
{
    uintptr_t *args = &proc->upcall_args[0];

    switch ((upcall_t)proc->upcall_code) {
    case upcall_code_log_int:
        upcall_log_int(proc, args[0]);
        break;
    case upcall_code_log_str:
        upcall_log_str(proc, (rust_str*)args[0]);
        break;
    case upcall_code_new_proc:
        *((rust_proc**)args[0]) =
            upcall_new_proc(proc, args[1], args[2],(size_t)args[3]);
        break;
    case upcall_code_del_proc:
        upcall_del_proc((rust_proc*)args[0]);
        break;
    case upcall_code_fail:
        upcall_fail(proc,
                    (char const *)args[0],
                    (char const *)args[1],
                    (size_t)args[2]);
        break;
    case upcall_code_malloc:
        *((uintptr_t*)args[0]) =
            upcall_malloc(proc, (size_t)args[1]);
        break;
    case upcall_code_free:
        upcall_free(proc, (void*)args[0]);
        break;
    case upcall_code_new_port:
        *((rust_port**)args[0]) =
            upcall_new_port(proc, (size_t)args[1]);
        break;
    case upcall_code_del_port:
        upcall_del_port(proc, (rust_port*)args[0]);
        break;
    case upcall_code_send:
        upcall_send(proc, (rust_port*)args[0], (void*)args[1]);
        break;
    case upcall_code_recv:
        upcall_recv(proc, (rust_port*)args[1]);
        break;
    case upcall_code_new_str:
        *((rust_str**)args[0]) = upcall_new_str(proc,
                                             (char const *)args[1],
                                             (size_t)args[2]);
        break;
    case upcall_code_grow_proc:
        upcall_grow_proc(proc, (size_t)args[0], (size_t)args[1]);
        break;
    case upcall_code_trace_word:
        upcall_trace_word(proc, args[0]);
        break;
    case upcall_code_trace_str:
        upcall_trace_str(proc, (char const *)args[0]);
        break;
    }
}


static void
rust_main_loop(uintptr_t main_fn, uintptr_t main_exit_proc_glue, rust_srv *srv)
{
    size_t live_allocs = 0;
    {
        rust_proc *proc;
        rust_rt rt(srv, live_allocs);

        rt.log(LOG_RT, "control is in rust runtime library");
        rt.logptr("main fn", main_fn);
        rt.logptr("main exit-proc glue", main_exit_proc_glue);

        rt.root_proc = new (rt) rust_proc(&rt, NULL, main_exit_proc_glue, main_fn, 0);
        add_proc_state_vec(&rt, rt.root_proc);
        proc = rt.sched();

        rt.logptr("root proc", (uintptr_t)proc);
        rt.logptr("proc->rust_sp", (uintptr_t)proc->rust_sp);

        while (proc) {

            rt.log(LOG_PROC, "activating proc 0x%" PRIxPTR,
                   (uintptr_t)proc);

            proc->state = proc_state_running;
            srv->activate(proc);

            rt.log(LOG_PROC,
                   "returned from proc 0x%" PRIxPTR " in state '%s'",
                   (uintptr_t)proc, state_names[proc->state]);
            /*
              rt->log(LOG_MEM,
              "sp:0x%" PRIxPTR ", "
              "stk:[0x%" PRIxPTR ", " "0x%" PRIxPTR "], "
              "stk->prev:0x%" PRIxPTR ", stk->next=0x%" PRIxPTR ", "
              "prev_sp:0x%" PRIxPTR ", " "prev_fp:0x%" PRIxPTR,
              proc->rust_sp, (uintptr_t) &proc->stk->data[0], proc->stk->limit,
              proc->stk->prev, proc->stk->next,
              proc->stk->prev_sp, proc->stk->prev_fp);
            */
            I(&rt, proc->rust_sp >= (uintptr_t) &proc->stk->data[0]);
            I(&rt, proc->rust_sp < proc->stk->limit);

            switch ((proc_state_t) proc->state) {

            case proc_state_running:
            case proc_state_failing:
                break;

            case proc_state_calling_c:
                handle_upcall(proc);
                if (proc->state == proc_state_calling_c)
                    proc->state = proc_state_running;
                break;

            case proc_state_blocked_exited:
                /* When a proc exits *itself* we do not yet kill it; for
                 * the time being we let it linger in the blocked-exiting
                 * state, as someone else still "owns" it. */
                proc->state = proc_state_running;
                proc_state_transition(&rt, proc,
                                      proc_state_running,
                                      proc_state_blocked_exited);
                break;

            case proc_state_blocked_reading:
            case proc_state_blocked_writing:
                I(&rt, 0);
                break;
            }

            proc = rt.sched();
        }

        rt.log(LOG_RT, "finished main loop");
    }
    if (live_allocs != 0) {
        srv->fatal("leaked memory in rust main loop", __FILE__, __LINE__);
    }
}

void
rust_srv::log(char const *str)
{
    printf("rt: %s\n", str);
}

void *
rust_srv::malloc(size_t bytes)
{
    return ::malloc(bytes);
}

void *
rust_srv::realloc(void *p, size_t bytes)
{
    return ::realloc(p, bytes);
}

void
rust_srv::free(void *p)
{
    ::free(p);
}

void
rust_srv::fatal(char const *expr, char const *file, size_t line)
{
    char buf[1024];
    snprintf(buf, sizeof(buf), "fatal, '%s' failed, %s:%d", expr, file, (int)line);
    log(buf);
    exit(1);
}

uintptr_t
rust_srv::lookup(char const *sym)
{
    uintptr_t res;

#ifdef __WIN32__
    /* FIXME: pass library name in as well. And use LoadLibrary not
     * GetModuleHandle, manually refcount. Oh, so much to do
     * differently. */
    const char *modules[2] = { "rustrt.dll", "msvcrt.dll" };
    for (size_t i = 0; i < sizeof(modules) / sizeof(const char *); ++i) {
        HMODULE lib = GetModuleHandle(modules[i]);
        if (!lib)
            fatal("GetModuleHandle", __FILE__, __LINE__);
        res = (uintptr_t)GetProcAddress(lib, sym);
        if (res)
            break;
    }
#else
    /* FIXME: dlopen, as above. */
    res = (uintptr_t)dlsym(RTLD_DEFAULT, sym);
#endif
    if (!res)
        fatal("srv->lookup", __FILE__, __LINE__);
    return res;
}

/* Native builtins. */

extern "C" CDECL char const *
str_buf(rust_proc *proc, rust_str *s)
{
    return (char const *)&s->data[0];
}

extern "C" CDECL rust_str*
implode(rust_proc *proc, rust_vec *v)
{
    /*
     * We received a vec of u32 unichars. Implode to a string.
     * FIXME: this needs to do a proper utf-8 encoding.
     */
    size_t i;
    rust_str *s;

    size_t fill = v->fill >> 2;
    s = upcall_new_str(proc, NULL, fill);

    uint32_t *src = (uint32_t*) &v->data[0];
    uint8_t *dst = &s->data[0];

    for (i = 0; i < fill; ++i)
        *dst++ = *src;

    return s;
}

extern "C" CDECL int
rust_start(uintptr_t main_fn,
           uintptr_t main_exit_proc_glue,
           void CDECL (*c_to_proc_glue)(rust_proc*))
{
    rust_srv srv(c_to_proc_glue);
    rust_main_loop(main_fn, main_exit_proc_glue, &srv);
    return 0;
}

/*
 * Local Variables:
 * mode: C++
 * fill-column: 70;
 * indent-tabs-mode: nil
 * c-basic-offset: 4
 * buffer-file-coding-system: utf-8-unix
 * compile-command: "make -k -C .. 2>&1 | sed -e 's/\\/x\\//x:\\//g'";
 * End:
 */
