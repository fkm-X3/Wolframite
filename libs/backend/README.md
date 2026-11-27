# Tungsten

Use Zig 0.17.1 for this project

## Are there even any projects using Tungsten:
Yes, the in-house lang project [Wolframite](https://github.com/fkm-X3/Wolframite) uses Tungsten.

## Is tungsten even a good alternative to LLVM:
Short anser: No, not yet. As it lacks major optermization and the compiling targets that LLVM has. This is being worked on by the soul maintainer (and anyone brave enough to install zig 0.17 and create a PR) so one day it will be a worthy competitor to LLVM.

## How does Tungsten produce executables?
Tungsten lowers its IR directly to x86-64 machine-code bytes and relocation records, then emits ELF64 or PE/COFF relocatable objects. Its internal Ferro linker combines those objects with the runtime archive to produce executables, without invoking an external assembler or linker.
