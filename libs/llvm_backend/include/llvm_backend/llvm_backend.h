// llvm_backend — a thin, stable C wrapper around the LLVM C++ API.
//
// The whole point of this layer is to insulate the rest of Wolframite (and
// eventually Zig itself) from LLVM's churn. LLVM breaks its C++ API on a
// near-monthly basis; we only ever have to fix THIS file (and its .cpp) when
// we bump the LLVM version, and we can lag behind LLVM releases on our own
// schedule instead of chasing "the LLVM dragon".
//
// This is the version-independent surface. It is NOT wired to real LLVM yet —
// every function is a stub. Callers compile against these declarations now,
// and the implementations get filled in later. Each stub records the intended
// LLVM call in its comments.
//
// Memory model: unless a function is documented otherwise, every returned
// `lvb_*` handle (and any `const char*` you get back from `lvb_*_to_string`)
// is owned by the `lvb_context` that produced it and is freed when that
// context is destroyed. The context is not thread-safe; use one per thread.

#ifndef LLVM_BACKEND_LLVM_BACKEND_H
#define LLVM_BACKEND_LLVM_BACKEND_H

#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Opaque handle types. These mirror the LLVM IR objects we will one day back
// each one with (Module, Function, BasicBlock, Value). Nothing about the
// concrete layout is public; treat them as opaque cookies.
// ---------------------------------------------------------------------------

typedef struct lvb_context    lvb_context;
typedef struct lvb_module     lvb_module;
typedef struct lvb_function   lvb_function;
typedef struct lvb_basicblock lvb_basicblock;
typedef struct lvb_value      lvb_value;
typedef struct lvb_type       lvb_type;

// Optimization level applied at codegen time. This tracks LLVM's set so we
// can pick the highest level for `--release` builds.
typedef enum lvb_opt_level {
    LVB_OPT_NONE = 0,   // Equivalent of LLVM -O0.
    LVB_OPT_LESS,       // -O1.
    LVB_OPT_DEFAULT,    // -O2.
    LVB_OPT_AGGRESSIVE, // -O3.
} lvb_opt_level;

// Pass manager level. Higher levels run more/stronger optimization passes.
typedef enum lvb_pass_level {
    LVB_PASS_NONE       = 0,
    LVB_PASS_FUNCTION,
    LVB_PASS_MODULE,
} lvb_pass_level;

// ---------------------------------------------------------------------------
// Context lifecycle
// ---------------------------------------------------------------------------

// Create a new backend context. Returns NULL on allocation failure.
lvb_context* lvb_context_create(void);

// Destroy a context and everything it owns. Passing NULL is a no-op.
void lvb_context_destroy(lvb_context* ctx);

// Create a new empty module inside `ctx` with the given name.
// Returns NULL on failure.
lvb_module* lvb_module_create(lvb_context* ctx, const char* name);

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

// Primitive types. Returned handles are owned by `ctx`.
lvb_type* lvb_type_void(lvb_context* ctx);
lvb_type* lvb_type_i1(lvb_context* ctx);
lvb_type* lvb_type_i8(lvb_context* ctx);
lvb_type* lvb_type_i32(lvb_context* ctx);
lvb_type* lvb_type_i64(lvb_context* ctx);
lvb_type* lvb_type_f32(lvb_context* ctx);
lvb_type* lvb_type_f64(lvb_context* ctx);
// Pointer to `pointee` (LLVM opaque or typed pointer depending on version).
lvb_type* lvb_type_pointer(lvb_context* ctx, lvb_type* pointee);
// Function type: `ret` return type, `params` array of `n_params` parameter
// types. `is_varargs` allows a trailing varargs ellipsis.
lvb_type* lvb_type_function(lvb_context* ctx, lvb_type* ret,
                            lvb_type* const* params, size_t n_params,
                            bool is_varargs);

// ---------------------------------------------------------------------------
// Functions & basic blocks
// ---------------------------------------------------------------------------

// Add a function to `module` with the given name, type and linkage.
// `is_external` makes it a declaration only (no body).
lvb_function* lvb_function_add(lvb_module* module, const char* name,
                               lvb_type* fn_type, bool is_external);

// Append a basic block to `function`. Returns NULL on failure.
lvb_basicblock* lvb_block_append(lvb_function* function, const char* name);

// Make `block` the insertion point for subsequent instructions.
void lvb_builder_set_insert(lvb_context* ctx, lvb_basicblock* block);

// ---------------------------------------------------------------------------
// Constants and primitive instructions
// ---------------------------------------------------------------------------

lvb_value* lvb_const_int(lvb_context* ctx, lvb_type* type, long long value);
lvb_value* lvb_const_fp(lvb_context* ctx, lvb_type* type, double value);
lvb_value* lvb_const_string(lvb_context* ctx, const char* str, size_t len,
                            bool null_terminated);

// Create an alloca for a value of `type`, with optional `name`.
lvb_value* lvb_insn_alloca(lvb_context* ctx, lvb_type* type, const char* name);

// The standard IR builder emits into whatever block was set with
// lvb_builder_set_insert, and returns a value handle (also owned by `ctx`).
lvb_value* lvb_insn_add(lvb_context* ctx, lvb_value* lhs, lvb_value* rhs);
lvb_value* lvb_insn_sub(lvb_context* ctx, lvb_value* lhs, lvb_value* rhs);
lvb_value* lvb_insn_mul(lvb_context* ctx, lvb_value* lhs, lvb_value* rhs);
lvb_value* lvb_insn_load(lvb_context* ctx, lvb_value* ptr);
void       lvb_insn_store(lvb_context* ctx, lvb_value* val, lvb_value* ptr);

lvb_value* lvb_insn_call(lvb_context* ctx, lvb_function* callee,
                         lvb_value* const* args, size_t n_args);
lvb_value* lvb_insn_call_extern(lvb_context* ctx, const char* callee,
                                lvb_value* const* args, size_t n_args,
                                lvb_type* ret_type);

void lvb_insn_br(lvb_context* ctx, lvb_basicblock* target);
void lvb_insn_br_if(lvb_context* ctx, lvb_value* cond,
                    lvb_basicblock* then_block, lvb_basicblock* else_block);
void lvb_insn_ret(lvb_context* ctx, lvb_value* val);
void lvb_insn_ret_void(lvb_context* ctx);

// ---------------------------------------------------------------------------
// Codegen / emission
// ---------------------------------------------------------------------------

// Compile `module` to object code using a pass pipeline tuned by
// `opt` and `passes`. Output goes to `out_path` (e.g. "out.obj").
// Returns 0 on success, non-zero on failure.
int lvb_module_emit_object(lvb_module* module, const char* out_path,
                           lvb_opt_level opt, lvb_pass_level passes);

// Compile `module` to native assembly text at `out_path` (e.g. "out.s").
// Returns 0 on success, non-zero on failure.
int lvb_module_emit_assembly(lvb_module* module, const char* out_path,
                             lvb_opt_level opt, lvb_pass_level passes);

// Print the module's textual IR (LLVM-IR style) into a caller-provided
// buffer. Returns the number of characters written (excluding NUL), or the
// required size (excluding NUL) if `buf` is NULL so the caller can size it.
size_t lvb_module_to_string(lvb_module* module, char* buf, size_t buf_len);

// ---------------------------------------------------------------------------
// Error reporting
// ---------------------------------------------------------------------------

// Human-readable description of the last error on `ctx`. Owned by `ctx` and
// valid until the next error or context destruction. Empty string if none.
const char* lvb_last_error(lvb_context* ctx);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // LLVM_BACKEND_LLVM_BACKEND_H
