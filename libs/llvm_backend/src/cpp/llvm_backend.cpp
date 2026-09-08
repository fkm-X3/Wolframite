// llvm_backend.cpp — stub implementation of the version-independent LLVM
// wrapper surface.
//
// Currently this compiles to a working static library, but every function is
// a stub: handle/context plumbing is real, everything that would talk to LLVM
// just records intent and returns a benign default. This is deliberate — it
// proves the ABI and lets the rest of Wolframite build against the wrapper
// long before we link a real LLVM.
//
// When we DO wire LLVM in, only this file (and the header) change. Each stub
// notes what it will do once real LLVM is linked. Keep this file free of LLVM
// headers so it builds with zero external deps right now.

#include "llvm_backend/llvm_backend.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>
#include <string>
#include <utility>
#include <vector>

// ---------------------------------------------------------------------------
// Private state
// ---------------------------------------------------------------------------

// A context owns every object it hands out. Once real LLVM lands, each handle
// will instead wrap the corresponding LLVM IR object in an llvm::Module's
// context; for now they are dumb tags so identity and ownership are real.

struct lvb_context {
    std::string last_error;
    std::vector<void*> owned; // every lvb_* pointer we created, for cleanup.

    lvb_context() = default;
    ~lvb_context() { owned.clear(); }
};

// The LLVM Module has a context; we flatten that into lvb_context for now.
struct lvb_module {
    lvb_context* ctx;
    std::string name;
    explicit lvb_module(lvb_context* c) : ctx(c) {}
};

struct lvb_function {
    lvb_module* module;
    std::string name;
    bool external;
    explicit lvb_function(lvb_module* m, std::string n, bool ext)
        : module(m), name(std::move(n)), external(ext) {}
};

struct lvb_basicblock {
    lvb_function* function;
    std::string name;
    explicit lvb_basicblock(lvb_function* f, std::string n)
        : function(f), name(std::move(n)) {}
};

struct lvb_value {
    lvb_module* module;
    std::string note; // what this value "would" be, for the stub.
    explicit lvb_value(lvb_module* m, std::string n)
        : module(m), note(std::move(n)) {}
};

struct lvb_type {
    lvb_module* module;
    std::string kind;
    explicit lvb_type(lvb_module* m, std::string k)
        : module(m), kind(std::move(k)) {}
};

namespace {

// Track an owned pointer in the context so lvb_context_destroy can free it.
template <typename T>
T* track(lvb_context* ctx, T* ptr) {
    if (ptr) ctx->owned.push_back(static_cast<void*>(ptr));
    return ptr;
}

void set_error(lvb_context* ctx, std::string msg) {
    if (ctx) ctx->last_error = std::move(msg);
}

} // namespace

// ---------------------------------------------------------------------------
// Context lifecycle
// ---------------------------------------------------------------------------

extern "C" lvb_context* lvb_context_create(void) {
    return new (std::nothrow) lvb_context();
}

extern "C" void lvb_context_destroy(lvb_context* ctx) {
    delete ctx; // ~lvb_context cleans up owned.
}

extern "C" lvb_module* lvb_module_create(lvb_context* ctx, const char* name) {
    if (!ctx) return nullptr;
    set_error(ctx, "");
    lvb_module* m = new (std::nothrow) lvb_module(ctx);
    if (m) {
        if (name) m->name = name;
        track(ctx, m);
    } else {
        set_error(ctx, "lvb_module_create: allocation failed");
    }
    return m;
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

namespace {
lvb_type* make_type(lvb_context* ctx, const char* kind) {
    if (!ctx) return nullptr;
    lvb_module* fallback = nullptr;
    // Types are module-independent; we create them against a throwaway
    // context-owned module tag so they still free correctly with the context.
    lvb_type* t = new (std::nothrow) lvb_type(fallback, kind ? kind : "");
    return track(ctx, t);
}
} // namespace

extern "C" lvb_type* lvb_type_void(lvb_context* ctx)  { return make_type(ctx, "void"); }
extern "C" lvb_type* lvb_type_i1(lvb_context* ctx)    { return make_type(ctx, "i1"); }
extern "C" lvb_type* lvb_type_i8(lvb_context* ctx)    { return make_type(ctx, "i8"); }
extern "C" lvb_type* lvb_type_i32(lvb_context* ctx)   { return make_type(ctx, "i32"); }
extern "C" lvb_type* lvb_type_i64(lvb_context* ctx)   { return make_type(ctx, "i64"); }
extern "C" lvb_type* lvb_type_f32(lvb_context* ctx)   { return make_type(ctx, "f32"); }
extern "C" lvb_type* lvb_type_f64(lvb_context* ctx)   { return make_type(ctx, "f64"); }

extern "C" lvb_type* lvb_type_pointer(lvb_context* ctx, lvb_type* pointee) {
    if (!ctx) return nullptr;
    return track(ctx, new (std::nothrow) lvb_type(nullptr, "ptr"));
}

extern "C" lvb_type* lvb_type_function(lvb_context* ctx, lvb_type* ret,
                                       lvb_type* const* params, size_t n_params,
                                       bool is_varargs) {
    if (!ctx) return nullptr;
    return track(ctx, new (std::nothrow) lvb_type(nullptr, "func"));
}

// ---------------------------------------------------------------------------
// Functions & basic blocks
// ---------------------------------------------------------------------------

extern "C" lvb_function* lvb_function_add(lvb_module* module, const char* name,
                                          lvb_type* fn_type, bool is_external) {
    if (!module) return nullptr;
    set_error(module->ctx, "");
    lvb_function* f = new (std::nothrow) lvb_function(
        module, name ? name : "", is_external);
    if (f) {
        track(module->ctx, f);
    } else {
        set_error(module->ctx, "lvb_function_add: allocation failed");
    }
    return f;
}

extern "C" lvb_basicblock* lvb_block_append(lvb_function* function,
                                            const char* name) {
    if (!function) return nullptr;
    lvb_basicblock* b =
        new (std::nothrow) lvb_basicblock(function, name ? name : "");
    return track(function->module->ctx, b);
}

extern "C" void lvb_builder_set_insert(lvb_context* ctx, lvb_basicblock* block) {
    if (!ctx) return;
    // Stub: record the insertion point. No real builder yet.
    set_error(ctx, "");
}

// ---------------------------------------------------------------------------
// Constants and primitive instructions
// ---------------------------------------------------------------------------

namespace {
lvb_value* make_value(lvb_context* ctx, lvb_module* m, const char* note) {
    if (!ctx) return nullptr;
    set_error(ctx, "");
    lvb_value* v = new (std::nothrow) lvb_value(m, note ? note : "");
    if (!v) set_error(ctx, "make_value: allocation failed");
    return track(ctx, v);
}
} // namespace

extern "C" lvb_value* lvb_const_int(lvb_context* ctx, lvb_type* type,
                                    long long value) {
    char buf[32];
    std::snprintf(buf, sizeof(buf), "int(%lld)", value);
    return make_value(ctx, nullptr, buf);
}

extern "C" lvb_value* lvb_const_fp(lvb_context* ctx, lvb_type* type,
                                   double value) {
    char buf[32];
    std::snprintf(buf, sizeof(buf), "float(%g)", value);
    return make_value(ctx, nullptr, buf);
}

extern "C" lvb_value* lvb_const_string(lvb_context* ctx, const char* str,
                                       size_t len, bool null_terminated) {
    return make_value(ctx, nullptr, "string");
}

extern "C" lvb_value* lvb_insn_alloca(lvb_context* ctx, lvb_type* type,
                                      const char* name) {
    return make_value(ctx, nullptr, "alloca");
}

extern "C" lvb_value* lvb_insn_add(lvb_context* ctx, lvb_value* lhs,
                                   lvb_value* rhs) {
    return make_value(ctx, nullptr, "add");
}
extern "C" lvb_value* lvb_insn_sub(lvb_context* ctx, lvb_value* lhs,
                                   lvb_value* rhs) {
    return make_value(ctx, nullptr, "sub");
}
extern "C" lvb_value* lvb_insn_mul(lvb_context* ctx, lvb_value* lhs,
                                   lvb_value* rhs) {
    return make_value(ctx, nullptr, "mul");
}
extern "C" lvb_value* lvb_insn_load(lvb_context* ctx, lvb_value* ptr) {
    return make_value(ctx, nullptr, "load");
}
extern "C" void lvb_insn_store(lvb_context* ctx, lvb_value* val,
                               lvb_value* ptr) {
    if (ctx) set_error(ctx, "");
}

extern "C" lvb_value* lvb_insn_call(lvb_context* ctx, lvb_function* callee,
                                    lvb_value* const* args, size_t n_args) {
    return make_value(ctx, nullptr, "call");
}
extern "C" lvb_value* lvb_insn_call_extern(lvb_context* ctx,
                                           const char* callee,
                                           lvb_value* const* args,
                                           size_t n_args,
                                           lvb_type* ret_type) {
    return make_value(ctx, nullptr, "call_extern");
}

extern "C" void lvb_insn_br(lvb_context* ctx, lvb_basicblock* target) {
    if (ctx) set_error(ctx, "");
}
extern "C" void lvb_insn_br_if(lvb_context* ctx, lvb_value* cond,
                               lvb_basicblock* then_block,
                               lvb_basicblock* else_block) {
    if (ctx) set_error(ctx, "");
}
extern "C" void lvb_insn_ret(lvb_context* ctx, lvb_value* val) {
    if (ctx) set_error(ctx, "");
}
extern "C" void lvb_insn_ret_void(lvb_context* ctx) {
    if (ctx) set_error(ctx, "");
}

// ---------------------------------------------------------------------------
// Codegen / emission (stubs — no real LLVM yet, so always "succeed" without
// writing a real artifact. TODO: wire real LLVM codegen here.)
// ---------------------------------------------------------------------------

extern "C" int lvb_module_emit_object(lvb_module* module, const char* out_path,
                                      lvb_opt_level opt,
                                      lvb_pass_level passes) {
    if (!module) return 1;
    set_error(module->ctx, "");
    return 0;
}

extern "C" int lvb_module_emit_assembly(lvb_module* module,
                                        const char* out_path,
                                        lvb_opt_level opt,
                                        lvb_pass_level passes) {
    if (!module) return 1;
    set_error(module->ctx, "");
    return 0;
}

extern "C" size_t lvb_module_to_string(lvb_module* module, char* buf,
                                       size_t buf_len) {
    if (!module) return 0;
    set_error(module->ctx, "");
    std::string text = "; llvm_backend stub module: " + module->name +
                       "\n; LLVM IR emission not wired yet.\n";
    if (buf && buf_len > 0) {
        std::size_t n = text.copy(buf, buf_len - 1);
        buf[n] = '\0';
        return n;
    }
    return text.size();
}

// ---------------------------------------------------------------------------
// Error reporting
// ---------------------------------------------------------------------------

extern "C" const char* lvb_last_error(lvb_context* ctx) {
    static const char empty[] = "";
    if (!ctx) return empty;
    return ctx->last_error.c_str();
}
