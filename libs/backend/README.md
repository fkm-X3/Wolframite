# Tungsten

Use Zig 0.17.0 for this project

## Are there even any projects using Tungsten:
Yes, the in-house lang project [Wolframite](https://github.com/fkm-X3/Wolframite) uses Tungsten.

## Is tungsten even a good alternative to LLVM:
Short anser: No, not yet. As it lacks major optermization and the compiling targets that LLVM has. This is being worked on by the soul maintainer (and anyone brave enough to install zig 0.16 and create a PR) so one day it will be a worthy competitor to LLVM.

## Why is tungsten not standalone yet?
Tungsten immits ASM then envokes NASM so its a dep for Tungsten in its current state. Eventually it will emmit x86-64 bytes directly into memory and compile into a binary through a ELF/PE section writer. This will increase the compilation speed of Tungsten and will make it standalone (Potentual for .elf files to come from Tungstens generation in future versions).
