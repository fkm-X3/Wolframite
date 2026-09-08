//! Root module for the llvm_backend_cpp static library.
//!
//! The actual implementation lives in `llvm_backend.cpp` (attached with
//! `addCSourceFiles` in the root build.zig). This Zig file exists only so the
//! library has a Zig `root` module; it is compiled but has no dependencies.