const std = @import("std");
const ir = @import("ir.zig");
const obj_elf = @import("obj_elf.zig");
const obj_pe = @import("obj_pe.zig");
const ferro = @import("ferro.zig");
const Allocator = std.mem.Allocator;

pub const CodeGen = struct {
    gpa: Allocator,
    module: *const ir.Module,

    param_count: u32,
    value_offsets: std.AutoHashMapUnmanaged(ir.Value, i32),
    alloca_offsets: std.AutoHashMapUnmanaged(u32, i32),

    // Object-emission state (only populated when emitting an object file).
    obj_text: std.ArrayList(u8),
    obj_data: std.ArrayList(u8),
    obj_relocs: std.ArrayList(obj_elf.Reloc),
    obj_symbols: std.ArrayList(obj_elf.Symbol),

    pub fn init(gpa: Allocator, module: *const ir.Module) @This() {
        return .{
            .gpa = gpa,
            .module = module,
            .param_count = 0,
            .value_offsets = .{},
            .alloca_offsets = .{},
            .obj_text = .empty,
            .obj_data = .empty,
            .obj_relocs = .empty,
            .obj_symbols = .empty,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.value_offsets.deinit(self.gpa);
        self.alloca_offsets.deinit(self.gpa);
        self.obj_text.deinit(self.gpa);
        self.obj_data.deinit(self.gpa);

        // Symbol names and relocation symbol names are individually
        // gpa-allocated (dupe/allocPrint) — free them before dropping the
        // ArrayList buffers.
        for (self.obj_symbols.items) |sym| {
            self.gpa.free(sym.name);
        }
        self.obj_symbols.deinit(self.gpa);

        for (self.obj_relocs.items) |rel| {
            self.gpa.free(rel.symbol);
        }
        self.obj_relocs.deinit(self.gpa);
    }

    // ========================================================================
    // Object emission: byte-level x86-64 encoder
    // ========================================================================

    /// Emit the whole module into `obj_text`/`obj_data` and populate
    /// `obj_symbols`/`obj_relocs`, producing an `obj_elf.ObjectInput` (the same
    /// input model feeds both the ELF64 and PE/COFF writers).
    pub fn emitObjectModule(self: *@This()) !obj_elf.ObjectInput {
        const data_section: u16 = 2;

        // Emit globals first so their addresses are known when referenced.
        if (self.module.globals.items.len > 0) {
            for (self.module.globals.items) |global| {
                const gname = self.module.strings.get(global.name);
                const data_off = @as(u64, @intCast(self.obj_data.items.len));
                switch (global.kind) {
                    .string => |data| {
                        const bytes = self.module.strings.get(data);
                        try self.obj_data.appendSlice(self.gpa, bytes);
                        try self.obj_data.append(self.gpa, 0);
                        try self.obj_symbols.append(self.gpa, .{
                            .name = try self.gpa.dupe(u8, gname),
                            .section_idx = data_section,
                            .value = data_off,
                            .size = @as(u64, @intCast(bytes.len)) + 1,
                            .binding = .global,
                            .is_func = false,
                        });
                    },
                    .fn_array => |funcs| {
                        for (funcs, 0..) |func_idx, j| {
                            const fname = self.module.strings.get(self.module.functions.items[func_idx].name);
                            const symbol = try std.fmt.allocPrint(self.gpa, "_{s}", .{fname});
                            defer self.gpa.free(symbol);
                            try self.obj_data.appendSlice(self.gpa, &[_]u8{0,0,0,0,0,0,0,0});
                            const entry_off = data_off + @as(u64, @intCast(j)) * 8;
                            try self.relocData(entry_off, symbol, .addr64, 0);
                        }
                        try self.obj_symbols.append(self.gpa, .{
                            .name = try self.gpa.dupe(u8, gname),
                            .section_idx = data_section,
                            .value = data_off,
                            .size = @as(u64, @intCast(funcs.len)) * 8,
                            .binding = .global,
                            .is_func = false,
                        });
                    },
                }
            }
        }

        // Emit externs as undefined symbols.
        for (self.module.externs.items) |ext| {
            const ename = self.module.strings.get(ext.name);
            const name = try self.gpa.dupe(u8, ename);
            try self.obj_symbols.append(self.gpa, .{
                .name = name,
                .section_idx = 0, // SHN_UNDEF / COFF undefined
                .value = 0,
                .size = 0,
                .binding = .global,
                .is_func = false,
            });
        }

        // Emit each function's machine code.
        for (self.module.functions.items) |*func| {
            try self.emitFunctionObject(func);
        }

        return obj_elf.ObjectInput{
            .text = self.obj_text.items,
            .data = self.obj_data.items,
            .bss_size = 0,
            .symbols = self.obj_symbols.items,
            .relocs = self.obj_relocs.items,
        };
    }

    fn emitFunctionObject(self: *@This(), func: *const ir.Function) !void {
        self.value_offsets.clearRetainingCapacity();
        self.alloca_offsets.clearRetainingCapacity();
        self.param_count = func.param_count;

        const name = self.module.strings.get(func.name);
        const fname = try std.fmt.allocPrint(self.gpa, "_{s}", .{name});

        const func_start = @as(u64, @intCast(self.obj_text.items.len));
        try self.obj_symbols.append(self.gpa, .{
            .name = fname,
            .section_idx = 1, // .text (section 1; section 0 is ELF NULL / SHN_UNDEF)
            .value = func_start,
            .size = 0,
            .binding = .global,
            .is_func = true,
        });

        // Prologue: push rbp; mov rbp, rsp
        try self.o8(0x55);
        try self.o8(0x48);
        try self.o8(0x89);
        try self.o8(0xe5);

        var value_slots: u32 = self.param_count;
        var alloca_data_slots: u32 = 0;
        for (func.instructions.items) |inst| {
            if (inst.producesValue()) value_slots += 1;
            if (inst.opcode == .alloca) alloca_data_slots += allocaSlotCount(func, inst);
        }

        const raw_size: u32 = 32 + (value_slots + alloca_data_slots) * 8;
        const frame_size: u32 = (raw_size + 15) & ~@as(u32, 15);

        var offset: i32 = 0;
        {
            var i: u32 = 0;
            while (i < self.param_count) : (i += 1) {
                offset -= 8;
                try self.value_offsets.put(self.gpa, @enumFromInt(i), offset);
            }
        }

        // Assign frame offsets to value-producing instructions.
        {
            var i: u32 = 0;
            while (i < @as(u32, @intCast(func.instructions.items.len))) : (i += 1) {
                const inst = func.instructions.items[i];
                const value_idx = self.param_count + i;
                if (inst.opcode == .alloca) {
                    const slots = allocaSlotCount(func, inst);
                    offset -= @as(i32, @intCast(slots * 8));
                    const data_off = offset;
                    offset -= 8;
                    try self.value_offsets.put(self.gpa, @enumFromInt(value_idx), offset);
                    try self.alloca_offsets.put(self.gpa, i, data_off);
                } else if (inst.producesValue()) {
                    offset -= 8;
                    try self.value_offsets.put(self.gpa, @enumFromInt(value_idx), offset);
                }
            }
        }

        // Stack-passed parameters (index >= 4).
        {
            var i: u32 = 4;
            while (i < self.param_count) : (i += 1) {
                const off = self.value_offsets.get(@enumFromInt(i)) orelse unreachable;
                // mov rax, qword [rsp + 48 + (i-4)*8] (modrm 0x84 + SIB 0x04 + disp32)
                try self.o8(0x48);
                try self.o8(0x8b);
                try self.o8(0x84);
                try self.o8(0x04);
                const disp_raw: u32 = 48 + (i - 4) * 8;
                try self.emitI32(@bitCast(disp_raw));
                // mov [rbp + off], rax (modrm 0x85 + disp32)
                try self.o8(0x48);
                try self.o8(0x89);
                try self.o8(0x85);
                try self.emitI32(off);
            }
        }

        if (frame_size > 0) {
            // sub rsp, imm8
            try self.o8(0x48);
            try self.o8(0x83);
            try self.o8(0xec);
            try self.o8(@truncate(frame_size));
        }

        const reg_rex = [_]u8{ 0x48, 0x48, 0x4c, 0x4c }; // rcx, rdx, r8, r9
        const reg_modrm = [_]u8{ 0x8d, 0x95, 0x85, 0x8d }; // [rbp+disp32] for rcx/rdx/r8/r9
        {
            var i: u32 = 0;
            while (i < self.param_count and i < 4) : (i += 1) {
                const off = self.value_offsets.get(@enumFromInt(i)) orelse unreachable;
                try self.o8(reg_rex[i]);
                try self.o8(0x89);
                try self.o8(reg_modrm[i]);
                try self.emitI32(off);
            }
        }

        for (func.blocks.items) |_block| {
            const start = @intFromEnum(_block.first_inst);
            var rel: u32 = 0;
            while (rel < _block.inst_count) : (rel += 1) {
                const inst = func.instructions.items[start + rel];
                const is_last = rel == _block.inst_count - 1;
                const value_idx = self.param_count + start + rel;

                if (is_last and (inst.opcode == .br or inst.opcode == .cond_br or inst.opcode == .ret or inst.opcode == .ret_void)) {
                    try self.emitControlFlowObject(func, inst);
                } else {
                    try self.emitInstructionObject(func, inst, value_idx);
                }
            }
        }

        // Epilogue: leave; ret
        try self.o8(0xc9);
        try self.o8(0xc3);

        // Patch function size.
        const func_end = @as(u64, @intCast(self.obj_text.items.len));
        const sym_idx = self.obj_symbols.items.len - 1;
        self.obj_symbols.items[sym_idx].size = func_end - func_start;
    }

    fn o8(self: *@This(), v: u8) !void {
        try self.obj_text.append(self.gpa, v);
    }

    fn emitI32(self: *@This(), v: i32) !void {
        const bytes = std.mem.asBytes(&v);
        for (bytes) |b| try self.o8(b);
    }

    fn emitI64(self: *@This(), v: i64) !void {
        const bytes = std.mem.asBytes(&v);
        for (bytes) |b| try self.o8(b);
    }

    /// Record a relocation site in .text at the current end of obj_text.
    fn relocText(self: *@This(), symbol: []const u8, kind: ferro.RelocKind, addend: i64) !void {
        const name = try self.gpa.dupe(u8, symbol);
        try self.obj_relocs.append(self.gpa, .{
            .section_idx = 1, // .text (section 1)
            .offset = @as(u64, @intCast(self.obj_text.items.len)),
            .symbol = name,
            .kind = kind,
            .addend = addend,
        });
    }

    /// Record a relocation site in .data at the given offset.
    fn relocData(self: *@This(), offset: u64, symbol: []const u8, kind: ferro.RelocKind, addend: i64) !void {
        const name = try self.gpa.dupe(u8, symbol);
        try self.obj_relocs.append(self.gpa, .{
            .section_idx = 2, // .data (section 2)
            .offset = offset,
            .symbol = name,
            .kind = kind,
            .addend = addend,
        });
    }

    fn valueOff(self: *@This(), v: u32) !i32 {
        return self.value_offsets.get(@enumFromInt(v)).?;
    }

    fn emitInstructionObject(self: *@This(), func: *const ir.Function, inst: ir.Instruction, value_idx: u32) !void {
        const ops = func.getOperands(inst.operands);

        switch (inst.opcode) {
            .iconst => {
                const bits: u64 = (@as(u64, ops[1]) << 32) | ops[0];
                const r = try self.valueOffsetOf(value_idx);
                // mov rax, imm64
                try self.o8(0x48);
                try self.o8(0xb8);
                try self.emitI64(@bitCast(bits));
                // mov [rbp + r], rax (modrm 0x85 = mod=10, reg=rax, r/m=rbp)
                try self.o8(0x48);
                try self.o8(0x89);
                try self.o8(0x85);
                try self.emitI32(r);
            },
            .fconst => {
                const bits: u64 = (@as(u64, ops[1]) << 32) | ops[0];
                // mov rax, imm64
                try self.o8(0x48);
                try self.o8(0xb8);
                try self.emitI64(@bitCast(bits));
                // movq xmm0, rax
                try self.o8(0x0f);
                try self.o8(0x6e);
                try self.o8(0xc0);
                const r = try self.valueOffsetOf(value_idx);
                // movsd [rbp + r], xmm0 (modrm 0x85 = mod=10, reg=xmm0, r/m=rbp)
                try self.o8(0xf2);
                try self.o8(0x0f);
                try self.o8(0x11);
                try self.o8(0x85);
                try self.emitI32(r);
            },
            .add, .sub, .mul, .and_op, .or_op, .xor_op => |op| {
                const r = try self.valueOffsetOf(value_idx);
                const a = try self.valueOff(ops[0]);
                const b = try self.valueOff(ops[1]);
                // mov rax, [rbp + a]
                try self.o8(0x48);
                try self.o8(0x8b);
                try self.o8(0x85);
                try self.emitI32(a);
                const opc: u8 = switch (op) {
                    .add => 0x03,   // add rax, [rbp+b]
                    .sub => 0x2b,   // sub rax, [rbp+b]
                    .mul => 0xaf,   // imul rax, [rbp+b] (0x0F AF /r)
                    .and_op => 0x23,// and rax, [rbp+b]
                    .or_op => 0x0b, // or rax, [rbp+b]
                    .xor_op => 0x31,// xor rax, [rbp+b]
                    else => unreachable,
                };
                const modrm = 0x85; // mod=10, reg=0(rax), r/m=101(rbp)
                if (op == .mul) {
                    try self.o8(0x48);
                    try self.o8(0x0f);
                    try self.o8(opc);
                } else {
                    try self.o8(0x48);
                    try self.o8(opc);
                }
                try self.o8(modrm);
                try self.emitI32(b);
                // mov [rbp + r], rax
                try self.o8(0x48);
                try self.o8(0x89);
                try self.o8(0x85);
                try self.emitI32(r);
            },
            .sdiv, .udiv, .srem, .urem => |op| {
                const r = try self.valueOffsetOf(value_idx);
                const a = try self.valueOff(ops[0]);
                const b = try self.valueOff(ops[1]);
                const is_signed = op == .sdiv or op == .srem;
                const is_rem = op == .srem or op == .urem;
                // mov rax, [rbp + a]
                try self.o8(0x48);
                try self.o8(0x8b);
                try self.o8(0x85);
                try self.emitI32(a);
                if (is_signed) {
                    try self.o8(0x48);
                    try self.o8(0x99); // cqo
                } else {
                    try self.o8(0x31);
                    try self.o8(0xd2); // xor edx, edx
                }
                // div/idiv qword [rbp + b]
                try self.o8(0x48);
                try self.o8(0xf7);
                try self.o8(0x85);
                try self.emitI32(b);
                // mov [rbp + r], rax/rdx
                const res_reg: u8 = if (is_rem) 0x82 else 0x80; // mov [rbp+r], rdx/rax
                try self.o8(0x48);
                try self.o8(res_reg);
                try self.o8(0x85);
                try self.emitI32(r);
            },
            .shl, .shr => |op| {
                const r = try self.valueOffsetOf(value_idx);
                const a = try self.valueOff(ops[0]);
                const b = try self.valueOff(ops[1]);
                // mov rax, [rbp + a]
                try self.o8(0x48);
                try self.o8(0x8b);
                try self.o8(0x85);
                try self.emitI32(a);
                // mov cl, byte [rbp + b]
                try self.o8(0x8a);
                try self.o8(0x4d);
                try self.emitI32(b);
                const mnemonic: u8 = if (op == .shl) 0xe3 else if (self.isSignedType(inst.type_idx)) 0xef else 0xc1; // shl/sar/shr rax, cl
                try self.o8(0x48);
                try self.o8(0x0f);
                try self.o8(mnemonic);
                // mov [rbp + r], rax
                try self.o8(0x48);
                try self.o8(0x89);
                try self.o8(0x85);
                try self.emitI32(r);
            },
            .fadd, .fsub, .fmul, .fdiv => |op| {
                const r = try self.valueOffsetOf(value_idx);
                const a = try self.valueOff(ops[0]);
                const b = try self.valueOff(ops[1]);
                const float = switch (self.module.getIrType(inst.type_idx)) {
                    .float => |f| f,
                    else => unreachable,
                };
                const mv: u8 = if (float == .f64) 0xf2 else 0xf3; // movsd/movss prefix
                const mn: u8 = switch (op) {
                    .fadd => 0x58, // addsd/addss xmm0, xmm1
                    .fsub => 0x5c, // subsd/subss
                    .fmul => 0x59, // mulsd/mulss
                    .fdiv => 0x5e, // divsd/divss
                    else => unreachable,
                };
                // {mv} xmm0, [rbp + a] (modrm 0x85 = mod=10, reg=xmm0, r/m=rbp)
                try self.o8(mv);
                try self.o8(0x0f);
                try self.o8(0x10);
                try self.o8(0x85);
                try self.emitI32(a);
                // {mv} xmm1, [rbp + b] (modrm 0x8d = mod=10, reg=xmm1, r/m=rbp)
                try self.o8(mv);
                try self.o8(0x0f);
                try self.o8(0x10);
                try self.o8(0x8d);
                try self.emitI32(b);
                // {mn} xmm0, xmm1 (modrm 0xc0 = mod=11, reg=xmm0, r/m=xmm1)
                try self.o8(mv);
                try self.o8(0x0f);
                try self.o8(mn);
                try self.o8(0xc0);
                // {mv} [rbp + r], xmm0 (modrm 0x85)
                try self.o8(mv);
                try self.o8(0x0f);
                try self.o8(0x11);
                try self.o8(0x85);
                try self.emitI32(r);
            },
            .icmp_eq, .icmp_ne, .icmp_slt, .icmp_sle, .icmp_sgt, .icmp_sge, .icmp_ult, .icmp_ule, .icmp_ugt, .icmp_uge => |cond| {
                const r = try self.valueOffsetOf(value_idx);
                const a = try self.valueOff(ops[0]);
                const b = try self.valueOff(ops[1]);
                const sc: u8 = switch (cond) {
                    .icmp_eq => 0x94, .icmp_ne => 0x95, .icmp_slt => 0x9c, .icmp_sle => 0x9e,
                    .icmp_sgt => 0x9f, .icmp_sge => 0x9d, .icmp_ult => 0x92, .icmp_ule => 0x96,
                    .icmp_ugt => 0x97, .icmp_uge => 0x93,
                    else => unreachable,
                };
                // mov rax, [rbp + a]
                try self.o8(0x48);
                try self.o8(0x8b);
                try self.o8(0x85);
                try self.emitI32(a);
                // cmp rax, [rbp + b]
                try self.o8(0x48);
                try self.o8(0x3b);
                try self.o8(0x85);
                try self.emitI32(b);
                // {sc} al
                try self.o8(0x0f);
                try self.o8(sc);
                // movzx eax, al
                try self.o8(0x0f);
                try self.o8(0xb6);
                try self.o8(0xc0);
                // mov [rbp + r], rax
                try self.o8(0x48);
                try self.o8(0x89);
                try self.o8(0x85);
                try self.emitI32(r);
            },
            .alloca => {
                const r = try self.valueOffsetOf(value_idx);
                const data_off = try self.allocaOffset(self.instIdx(value_idx));
                // lea rax, [rbp + data_off]
                try self.o8(0x48);
                try self.o8(0x8d);
                try self.o8(0x85);
                try self.emitI32(data_off);
                // mov [rbp + r], rax
                try self.o8(0x48);
                try self.o8(0x89);
                try self.o8(0x85);
                try self.emitI32(r);
            },
            .load => {
                const r = try self.valueOffsetOf(value_idx);
                const ptr = try self.valueOff(ops[0]);
                // mov rax, [rbp + ptr]
                try self.o8(0x48);
                try self.o8(0x8b);
                try self.o8(0x85);
                try self.emitI32(ptr);
                // mov rax, [rax]
                try self.o8(0x48);
                try self.o8(0x8b);
                try self.o8(0x00);
                // mov [rbp + r], rax
                try self.o8(0x48);
                try self.o8(0x89);
                try self.o8(0x85);
                try self.emitI32(r);
            },
            .store => {
                const ptr = try self.valueOff(ops[0]);
                const val = try self.valueOff(ops[1]);
                // mov rax, [rbp + ptr]
                try self.o8(0x48);
                try self.o8(0x8b);
                try self.o8(0x85);
                try self.emitI32(ptr);
                // mov rdx, [rbp + val]
                try self.o8(0x48);
                try self.o8(0x8b);
                try self.o8(0x55);
                try self.emitI32(val);
                // mov [rax], rdx
                try self.o8(0x48);
                try self.o8(0x89);
                try self.o8(0x10);
            },
            .ptr_add => {
                const r = try self.valueOffsetOf(value_idx);
                const a = try self.valueOff(ops[0]);
                const b = try self.valueOff(ops[1]);
                // mov rax, [rbp + a]
                try self.o8(0x48);
                try self.o8(0x8b);
                try self.o8(0x85);
                try self.emitI32(a);
                // add rax, [rbp + b]
                try self.o8(0x48);
                try self.o8(0x03);
                try self.o8(0x85);
                try self.emitI32(b);
                // mov [rbp + r], rax
                try self.o8(0x48);
                try self.o8(0x89);
                try self.o8(0x85);
                try self.emitI32(r);
            },
            .malloc => return error.LibcNotLinked,
            .global_addr => {
                const r = try self.valueOffsetOf(value_idx);
                const global = self.module.globals.items[ops[0]];
                const gname = self.module.strings.get(global.name);
                // lea rax, [rel __g{d}] (relocation)
                try self.o8(0x48);
                try self.o8(0x8d);
                try self.o8(0x05);
                try self.relocText(gname, .addr64, 0);
                try self.emitI32(0); // placeholder
                // mov [rbp + r], rax
                try self.o8(0x48);
                try self.o8(0x89);
                try self.o8(0x85);
                try self.emitI32(r);
            },
            .func_addr => {
                const r = try self.valueOffsetOf(value_idx);
                const target_func = &self.module.functions.items[ops[0]];
                const target_name = self.module.strings.get(target_func.name);
                const fname = try std.fmt.allocPrint(self.gpa, "_{s}", .{target_name});
                defer self.gpa.free(fname);
                // lea rax, [rel _{name}] (relocation)
                try self.o8(0x48);
                try self.o8(0x8d);
                try self.o8(0x05);
                try self.relocText(fname, .addr64, 0);
                try self.emitI32(0); // placeholder
                // mov [rbp + r], rax
                try self.o8(0x48);
                try self.o8(0x89);
                try self.o8(0x85);
                try self.emitI32(r);
            },
            .call => {
                const target_func = &self.module.functions.items[ops[0]];
                const target_name = self.module.strings.get(target_func.name);
                const fname = try std.fmt.allocPrint(self.gpa, "_{s}", .{target_name});
                defer self.gpa.free(fname);
                const arg_count: u32 = @intCast(ops.len - 1);
                const extra_stack = try self.emitCallSetupObject(ops, arg_count);
                // call _{name} (relocation)
                try self.o8(0xe8);
                try self.relocText(fname, .pc32, -4);
                try self.emitI32(0); // placeholder
                if (extra_stack > 0) {
                    try self.o8(0x48);
                    try self.o8(0x83);
                    try self.o8(0xc4);
                    try self.o8(@truncate(extra_stack));
                }
                if (inst.producesValue()) {
                    const r = try self.valueOffsetOf(value_idx);
                    try self.o8(0x48);
                    try self.o8(0x89);
                    try self.o8(0x85);
                    try self.emitI32(r);
                }
            },
            .call_ptr => {
                const callee_off = try self.valueOff(ops[0]);
                const visible_arg_count: u32 = if (ops.len > 1) @intCast(ops.len - 1) else 0;
                const total_arg_count: u32 = visible_arg_count + 1;
                const reg_args = [_]u8{ 0xc1, 0xc2, 0xc8, 0xc9 };
                const num_stack_args_total: u32 = if (total_arg_count > 4) total_arg_count - 4 else 0;
                var extra_stack: u32 = 32;
                if (num_stack_args_total > 0) {
                    extra_stack += num_stack_args_total * 8;
                    if (extra_stack % 16 != 0) extra_stack += 8;
                }
                if (extra_stack > 0) {
                    try self.o8(0x48);
                    try self.o8(0x83);
                    try self.o8(0xec);
                    try self.o8(@truncate(extra_stack));
                }
                // mov r10, [rbp + callee_off]
                try self.o8(0x4c);
                try self.o8(0x8b);
                try self.o8(0x95);
                try self.emitI32(callee_off);
                // Stack args first
                {
                    var i: u32 = 0;
                    while (i < visible_arg_count) : (i += 1) {
                        const arg_slot = i + 1;
                        if (arg_slot >= 4) {
                            const stack_pos: i32 = 32 + @as(i32, @intCast(arg_slot - 4)) * 8;
                            const arg_off = try self.valueOff(ops[1 + i]);
                            try self.o8(0x48);
                            try self.o8(0x8b);
                            try self.o8(0x85);
                            try self.emitI32(arg_off);
                            try self.o8(0x48);
                            try self.o8(0x89);
                            try self.o8(0x44);
                            try self.o8(0x24);
                            try self.emitI32(stack_pos);
                        }
                    }
                }
                // Hidden env as argument 0: mov rcx, qword [r10+8]
                try self.o8(0x4c);
                try self.o8(0x8b);
                try self.o8(0x4a);
                try self.o8(0x08);
                // Visible args in register slots
                {
                    var i: u32 = 0;
                    while (i < visible_arg_count) : (i += 1) {
                        const arg_slot = i + 1;
                        if (arg_slot < 4) {
                            const arg_off = try self.valueOff(ops[1 + i]);
                            try self.o8(0x48);
                            try self.o8(0x8b);
                            try self.o8(reg_args[i]);
                            try self.emitI32(arg_off);
                        }
                    }
                }
                // Callee address last, then call
                try self.o8(0x4c);
                try self.o8(0x8b);
                try self.o8(0x42); // mov rax, qword [r10+0]
                try self.o8(0x00);
                try self.o8(0xff);
                try self.o8(0xd0); // call rax
                if (extra_stack > 0) {
                    try self.o8(0x48);
                    try self.o8(0x83);
                    try self.o8(0xc4);
                    try self.o8(@truncate(extra_stack));
                }
                if (inst.producesValue()) {
                    const r = try self.valueOffsetOf(value_idx);
                    try self.o8(0x48);
                    try self.o8(0x89);
                    try self.o8(0x85);
                    try self.emitI32(r);
                }
            },
            .extern_call => {
                const ext_name = self.module.strings.get(self.module.externs.items[ops[0]].name);
                const arg_count: u32 = @intCast(ops.len - 1);
                const extra_stack = try self.emitCallSetupObject(ops, arg_count);
                // call {ext_name} (relocation)
                try self.o8(0xe8);
                try self.relocText(ext_name, .pc32, -4);
                try self.emitI32(0); // placeholder
                if (extra_stack > 0) {
                    try self.o8(0x48);
                    try self.o8(0x83);
                    try self.o8(0xc4);
                    try self.o8(@truncate(extra_stack));
                }
            },
            .phi => {
                try self.o8(0x90); // nop placeholder
            },
            else => return error.UnsupportedOpcode,
        }
    }

    fn valueOffsetOf(self: *@This(), value_idx: u32) !i32 {
        return self.value_offsets.get(@enumFromInt(value_idx)).?;
    }

    fn isSignedType(self: *@This(), type_idx: ir.TypeIdx) bool {
        return switch (self.module.getIrType(type_idx)) {
            .int => |it| it.signed,
            else => false,
        };
    }

    /// Convert a value_idx back to the instruction index within its function.
    fn instIdx(self: *@This(), value_idx: u32) u32 {
        return value_idx - self.param_count;
    }

    fn allocaOffset(self: *@This(), inst_idx: u32) !i32 {
        return self.alloca_offsets.get(inst_idx).?;
    }

    /// Shared call preamble for object emission: reserve shadow space + stack
    /// arg space, marshal args into registers/stack. Returns bytes reserved.
    fn emitCallSetupObject(self: *@This(), ops: []const u32, arg_count: u32) !u32 {
        const reg_rex = [_]u8{ 0x48, 0x48, 0x4c, 0x4c };
        const reg_modrm = [_]u8{ 0x8d, 0x95, 0x85, 0x8d }; // [rbp+disp32] for rcx/rdx/r8/r9
        const num_reg_args: u32 = @min(arg_count, 4);
        const num_stack_args: u32 = if (arg_count > 4) arg_count - 4 else 0;

        var extra_stack: u32 = 32;
        if (num_stack_args > 0) {
            extra_stack += num_stack_args * 8;
            if (extra_stack % 16 != 0) extra_stack += 8;
        }

        if (extra_stack > 0) {
            try self.o8(0x48);
            try self.o8(0x83);
            try self.o8(0xec);
            try self.o8(@truncate(extra_stack));
        }

        {
            var i: u32 = 0;
            while (i < num_reg_args) : (i += 1) {
                const arg_off = try self.valueOff(ops[1 + i]);
                try self.o8(reg_rex[i]);
                try self.o8(0x89);
                try self.o8(reg_modrm[i]);
                try self.emitI32(arg_off);
            }
        }

        {
            var i: u32 = arg_count;
            while (i > 4) {
                i -= 1;
                const arg_off = try self.valueOff(ops[1 + i]);
                const stack_pos: i32 = 32 + @as(i32, @intCast(i - 4)) * @as(i32, 8);
                try self.o8(0x48);
                try self.o8(0x8b);
                try self.o8(0x85);
                try self.emitI32(arg_off);
                try self.o8(0x48);
                try self.o8(0x89);
                try self.o8(0x44);
                try self.o8(0x24);
                try self.emitI32(stack_pos);
            }
        }

        return extra_stack;
    }

    fn emitControlFlowObject(self: *@This(), func: *const ir.Function, inst: ir.Instruction) !void {
        const ops = func.getOperands(inst.operands);
        switch (inst.opcode) {
            .br => {
            },
            .cond_br => {
                const cond_off = try self.valueOff(ops[0]);
                // mov rax, [rbp + cond_off] (modrm 0x85)
                try self.o8(0x48);
                try self.o8(0x8b);
                try self.o8(0x85);
                try self.emitI32(cond_off);
                // cmp rax, 0
                try self.o8(0x48);
                try self.o8(0x83);
                try self.o8(0xf8);
                try self.o8(0x00);
                // je +8
                try self.o8(0x74);
                try self.o8(0x08);
                // jmp rel32 (placeholder)
                try self.o8(0xe9);
                try self.emitI32(0);
            },
            .ret => {
                const val_off = try self.valueOff(ops[0]);
                // mov rax, [rbp + val_off] (modrm 0x85)
                try self.o8(0x48);
                try self.o8(0x8b);
                try self.o8(0x85);
                try self.emitI32(val_off);
                try self.o8(0xc9);
                try self.o8(0xc3);
            },
            .ret_void => {
                try self.o8(0xc9);
                try self.o8(0xc3);
            },
            else => unreachable,
        }
    }

    /// Returns true if any instruction in the module calls `malloc`.
    fn moduleUsesMalloc(self: *const @This()) bool {
        for (self.module.functions.items) |func| {
            for (func.instructions.items) |inst| {
                if (inst.opcode == .malloc) return true;
            }
        }
        return false;
    }

    /// Number of 8-byte frame slots an `alloca` occupies. An operand-less
    /// alloca reserves 8 bytes; an alloca with a size operand reserves
    /// `ceil(size / 8)` slots.
    fn allocaSlotCount(func: *const ir.Function, inst: ir.Instruction) u32 {
        const ops = func.getOperands(inst.operands);
        const size: u32 = if (ops.len == 0) 8 else ops[0];
        return (size + 7) / 8;
    }

};

// ============================================================================
// Tests
// ============================================================================


test "object emission: trivial main returns 42 (ELF64)" {
    var module = ir.Module.empty;
    defer module.deinit(std.testing.allocator);

    var builder = ir.Builder.init(std.testing.allocator, &module);
    const i32_ty = try builder.addIntType(true, 32);
    const void_ty = try builder.addVoidType();
    _ = void_ty;

    const main = try builder.addFunction("main", i32_ty, 0);
    builder.setCurrentFunction(main);
    const entry = try builder.appendBlock();
    builder.setCurrentBlock(entry);
    const forty_two = try builder.buildIntConst(i32_ty, 42);
    _ = try builder.buildRet(forty_two);

    var cg = CodeGen.init(std.testing.allocator, &module);
    defer cg.deinit();
    const input = try cg.emitObjectModule();

    var w = obj_elf.Writer.init(std.testing.allocator);
    defer w.deinit();
    const bytes = try w.writeObject(input);
    defer std.testing.allocator.free(bytes);

    // ELF header checks.
    try std.testing.expectEqualSlices(u8, bytes[0..4], &[_]u8{ 0x7f, 'E', 'L', 'F' });
    try std.testing.expectEqual(2, bytes[4]); // ELFCLASS64
    try std.testing.expectEqual(1, bytes[5]); // ELFDATA2LSB
    try std.testing.expectEqual(1, readU16(bytes, 16)); // ET_REL
    try std.testing.expectEqual(62, readU16(bytes, 18)); // EM_X86_64

    // .text section present with code.
    const e_shoff = readU64(bytes, 40);
    const e_shnum = readU16(bytes, 60);
    try std.testing.expectEqual(9, e_shnum);
    const sh_text_off = e_shoff + 1 * 64;
    try std.testing.expectEqual(1, readU32(bytes, sh_text_off + 4)); // SHT_PROGBITS
    const text_off = readU64(bytes, sh_text_off + 24);
    const text_size = readU64(bytes, sh_text_off + 32);
    try std.testing.expect(text_size > 0);
    // Should contain ret (0xc3) somewhere in .text.
    var found_ret = false;
    for (bytes[text_off..text_off + text_size]) |b| { if (b == 0xc3) found_ret = true; }
    try std.testing.expect(found_ret);

    // _main symbol in .text.
    const sh_symtab_off = e_shoff + 4 * 64;
    const symtab_offset = readU64(bytes, sh_symtab_off + 24);
    const sym1 = symtab_offset + 24; // skip STN_UNDEF
    try std.testing.expectEqual(1, readU16(bytes, sym1 + 6)); // st_shndx = .text (1)
}

test "object emission: extern call produces undefined symbol + PC32 relocation (ELF64)" {
    var module = ir.Module.empty;
    defer module.deinit(std.testing.allocator);

    var builder = ir.Builder.init(std.testing.allocator, &module);
    const i32_ty = try builder.addIntType(true, 32);
    const void_ty = try builder.addVoidType();

    const main = try builder.addFunction("main", i32_ty, 0);
    builder.setCurrentFunction(main);
    const entry = try builder.appendBlock();
    builder.setCurrentBlock(entry);
    _ = try builder.buildExternCall("wfr_std_print", void_ty, &[_]ir.Value{});
    const zero = try builder.buildIntConst(i32_ty, 0);
    _ = try builder.buildRet(zero);

    var cg = CodeGen.init(std.testing.allocator, &module);
    defer cg.deinit();
    const input = try cg.emitObjectModule();

    var w = obj_elf.Writer.init(std.testing.allocator);
    defer w.deinit();
    const bytes = try w.writeObject(input);
    defer std.testing.allocator.free(bytes);

    // ELF header.
    try std.testing.expectEqualSlices(u8, bytes[0..4], &[_]u8{ 0x7f, 'E', 'L', 'F' });

    // wfr_std_print is an undefined symbol resolved against wfr_std at link time.
    const e_shoff = readU64(bytes, 40);
    const sh_symtab_off = e_shoff + 4 * 64;
    const symtab_offset = readU64(bytes, sh_symtab_off + 24);
    // symbol order: 0=STN_UNDEF, 1=wfr_std_print (extern), 2=_main (function)
    const sym_print = symtab_offset + 24 * 1;
    try std.testing.expectEqual(0, readU16(bytes, sym_print + 6)); // st_shndx = SHN_UNDEF

    // .rela.text has a PC32 relocation for wfr_std_print.
    const sh_rela_off = e_shoff + 6 * 64;
    try std.testing.expectEqual(4, readU32(bytes, sh_rela_off + 4)); // SHT_RELA
    const rela_off = readU64(bytes, sh_rela_off + 24);
    const rela_size = readU64(bytes, sh_rela_off + 32);
    try std.testing.expectEqual(24, rela_size);
    const r_type: u32 = @truncate(readU64(bytes, rela_off + 8) & 0xFFFF_FFFF);
    try std.testing.expectEqual(2, r_type); // R_X86_64_PC32
}

test "object emission: global string literal in .data with ADDR64 relocation (ELF64)" {
    var module = ir.Module.empty;
    defer module.deinit(std.testing.allocator);

    var builder = ir.Builder.init(std.testing.allocator, &module);
    const i32_ty = try builder.addIntType(true, 32);
    const ptr_ty = try builder.addPointerType(i32_ty);
    const void_ty = try builder.addVoidType();
    _ = void_ty;

    const str_global = try builder.addStringGlobal("__g0", "hi");

    const main = try builder.addFunction("main", i32_ty, 0);
    builder.setCurrentFunction(main);
    const entry = try builder.appendBlock();
    builder.setCurrentBlock(entry);
    _ = try builder.buildGlobalAddr(ptr_ty, str_global);
    const zero = try builder.buildIntConst(i32_ty, 0);
    _ = try builder.buildRet(zero);

    var cg = CodeGen.init(std.testing.allocator, &module);
    defer cg.deinit();
    const input = try cg.emitObjectModule();

    var w = obj_elf.Writer.init(std.testing.allocator);
    defer w.deinit();
    const bytes = try w.writeObject(input);
    defer std.testing.allocator.free(bytes);

    // ELF header.
    try std.testing.expectEqualSlices(u8, bytes[0..4], &[_]u8{ 0x7f, 'E', 'L', 'F' });

    // .data section present.
    const e_shoff = readU64(bytes, 40);
    const sh_data_off = e_shoff + 2 * 64;
    try std.testing.expectEqual(1, readU32(bytes, sh_data_off + 4)); // SHT_PROGBITS
    const data_off = readU64(bytes, sh_data_off + 24);
    const data_size = readU64(bytes, sh_data_off + 32);
    try std.testing.expectEqual(3, data_size); // "hi\0"
    try std.testing.expectEqualSlices(u8, bytes[data_off..data_off + 3], &[_]u8{ 'h', 'i', 0 });

    // __g0 symbol in .data.
    const sh_symtab_off = e_shoff + 4 * 64;
    const symtab_offset = readU64(bytes, sh_symtab_off + 24);
    const sym_g0 = symtab_offset + 24 * 1; // symbol 1 = __g0
    try std.testing.expectEqual(2, readU16(bytes, sym_g0 + 6)); // st_shndx = .data (2)

    // .rela.text has ADDR64 relocation for __g0 (the lea instruction is in .text).
    const sh_rela_off = e_shoff + 6 * 64;
    try std.testing.expectEqual(4, readU32(bytes, sh_rela_off + 4)); // SHT_RELA
    const rela_off = readU64(bytes, sh_rela_off + 24);
    const rela_size = readU64(bytes, sh_rela_off + 32);
    try std.testing.expectEqual(24, rela_size);
    const r_type: u32 = @truncate(readU64(bytes, rela_off + 8) & 0xFFFF_FFFF);
    try std.testing.expectEqual(1, r_type); // R_X86_64_64
}

test "object emission: function call between two functions (ELF64)" {
    var module = ir.Module.empty;
    defer module.deinit(std.testing.allocator);

    var builder = ir.Builder.init(std.testing.allocator, &module);
    const i32_ty = try builder.addIntType(true, 32);

    // callee(i32) -> i32 { return n; }
    const callee = try builder.addFunction("callee", i32_ty, 1);
    builder.setCurrentFunction(callee);
    const c_entry = try builder.appendBlock();
    builder.setCurrentBlock(c_entry);
    const n = @as(ir.Value, @enumFromInt(0));
    _ = try builder.buildRet(n);

    // main(i32) -> i32 { return callee(n); }
    const main = try builder.addFunction("main", i32_ty, 1);
    builder.setCurrentFunction(main);
    const m_entry = try builder.appendBlock();
    builder.setCurrentBlock(m_entry);
    const n2 = @as(ir.Value, @enumFromInt(0));
    _ = try builder.buildCall(callee, i32_ty, &[_]ir.Value{ n2 });
    const zero = try builder.buildIntConst(i32_ty, 0);
    _ = try builder.buildRet(zero);

    var cg = CodeGen.init(std.testing.allocator, &module);
    defer cg.deinit();
    const input = try cg.emitObjectModule();

    var w = obj_elf.Writer.init(std.testing.allocator);
    defer w.deinit();
    const bytes = try w.writeObject(input);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualSlices(u8, bytes[0..4], &[_]u8{ 0x7f, 'E', 'L', 'F' });
    try std.testing.expectEqual(1, readU16(bytes, 16)); // ET_REL
    try std.testing.expectEqual(62, readU16(bytes, 18)); // EM_X86_64

    const e_shoff = readU64(bytes, 40);
    const e_shnum = readU16(bytes, 60);
    try std.testing.expectEqual(9, e_shnum);

    // .text section with code.
    const sh_text_off = e_shoff + 1 * 64;
    try std.testing.expectEqual(1, readU32(bytes, sh_text_off + 4)); // SHT_PROGBITS
    const text_off = readU64(bytes, sh_text_off + 24);
    const text_size = readU64(bytes, sh_text_off + 32);
    try std.testing.expect(text_size > 0);
    var found_ret = false;
    for (bytes[text_off..], 0..) |b, i| {
        if (i < text_size and b == 0xc3) found_ret = true;
    }
    try std.testing.expect(found_ret);

    // Two function symbols in .text: _callee (idx 1) then _main (idx 2).
    const sh_symtab_off = e_shoff + 4 * 64;
    const symtab_offset = readU64(bytes, sh_symtab_off + 24);
    const sym_callee = symtab_offset + 24 * 1;
    const sym_main = symtab_offset + 24 * 2;
    try std.testing.expectEqual(1, readU16(bytes, sym_callee + 6)); // st_shndx = .text (1)
    try std.testing.expectEqual(1, readU16(bytes, sym_main + 6)); // st_shndx = .text (1)
    // st_info: global binding (1) << 4 | func type (2) = 0x12
    try std.testing.expectEqual(0x12, bytes[sym_callee + 4]);
    try std.testing.expectEqual(0x12, bytes[sym_main + 4]);

    // .rela.text: one PC32 relocation for _callee (symtab index 1).
    const sh_rela_off = e_shoff + 6 * 64;
    try std.testing.expectEqual(4, readU32(bytes, sh_rela_off + 4)); // SHT_RELA
    const rela_size = readU64(bytes, sh_rela_off + 32);
    try std.testing.expectEqual(24, rela_size);
    const rela_off = readU64(bytes, sh_rela_off + 24);
    const r_info = readU64(bytes, rela_off + 8);
    const r_sym: u32 = @truncate(r_info >> 32);
    const r_type: u32 = @truncate(r_info & 0xFFFF_FFFF);
    try std.testing.expectEqual(1, r_sym); // _callee
    try std.testing.expectEqual(2, r_type); // R_X86_64_PC32
    try std.testing.expectEqual(-4, readI64(bytes, rela_off + 16));
}

test "object emission: closure env + call_ptr (ELF64)" {
    var module = ir.Module.empty;
    defer module.deinit(std.testing.allocator);

    var builder = ir.Builder.init(std.testing.allocator, &module);
    const i64_ty = try builder.addIntType(true, 64);

    // __closure_0(i64 env, i64 x) -> i64 { return *env + x; }
    const lifted = try builder.addFunction("__closure_0", i64_ty, 2);
    builder.setCurrentFunction(lifted);
    const l_entry = try builder.appendBlock();
    builder.setCurrentBlock(l_entry);
    const env_param = @as(ir.Value, @enumFromInt(0));
    const x_param = @as(ir.Value, @enumFromInt(1));
    const captured = try builder.buildLoad(i64_ty, env_param);
    _ = try builder.buildRet(try builder.buildAdd(i64_ty, captured, x_param));

    // caller(i64) -> i64 { fv = func_addr(__closure_0) + env{40}; return call_ptr fv(x); }
    const sig = try builder.addFunctionType(i64_ty, &.{i64_ty});
    const fv_ty = try builder.addFunctionValueType(sig);
    const caller = try builder.addFunction("caller", i64_ty, 1);
    builder.setCurrentFunction(caller);
    const c_entry = try builder.appendBlock();
    builder.setCurrentBlock(c_entry);
    const x_arg = @as(ir.Value, @enumFromInt(0));

    const fn_addr = try builder.buildFuncAddr(i64_ty, lifted);
    const forty = try builder.buildIntConst(i64_ty, 40);
    const env = try builder.buildEnvRecord(&.{.{ .type_idx = i64_ty, .value = forty }});
    const fv = try builder.buildFnValue(fv_ty, fn_addr, env);
    const result = try builder.buildCallPtr(i64_ty, fv, &.{x_arg});
    _ = try builder.buildRet(result);

    var cg = CodeGen.init(std.testing.allocator, &module);
    defer cg.deinit();
    const input = try cg.emitObjectModule();

    var w = obj_elf.Writer.init(std.testing.allocator);
    defer w.deinit();
    const bytes = try w.writeObject(input);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualSlices(u8, bytes[0..4], &[_]u8{ 0x7f, 'E', 'L', 'F' });

    const e_shoff = readU64(bytes, 40);
    const sh_text_off = e_shoff + 1 * 64;
    const text_off = readU64(bytes, sh_text_off + 24);
    const text_size = readU64(bytes, sh_text_off + 32);

    // Indirect call through the register: "call rax" = 0xff 0xd0.
    var found_call_rax = false;
    for (bytes[text_off..], 0..) |b, i| {
        if (i < text_size and i + 1 < text_size and b == 0xff and bytes[text_off + i + 1] == 0xd0) {
            found_call_rax = true;
        }
    }
    try std.testing.expect(found_call_rax);

    // _lifted and _caller are defined function symbols in .text.
    const sh_symtab_off = e_shoff + 4 * 64;
    const symtab_offset = readU64(bytes, sh_symtab_off + 24);
    const sym_lifted = symtab_offset + 24 * 1;
    const sym_caller = symtab_offset + 24 * 2;
    try std.testing.expectEqual(1, readU16(bytes, sym_lifted + 6)); // st_shndx = .text (1)
    try std.testing.expectEqual(1, readU16(bytes, sym_caller + 6)); // st_shndx = .text (1)

    // func_addr emitted an ADDR64 relocation for "_lifted" in .text.
    const sh_rela_off = e_shoff + 6 * 64;
    try std.testing.expectEqual(4, readU32(bytes, sh_rela_off + 4)); // SHT_RELA
    const rela_size = readU64(bytes, sh_rela_off + 32);
    try std.testing.expect(rela_size >= 24);
    const rela_off = readU64(bytes, sh_rela_off + 24);
    var found_addr64 = false;
    const entries = rela_size / 24;
    var e: u64 = 0;
    while (e < entries) : (e += 1) {
        const r_info = readU64(bytes, rela_off + e * 24 + 8);
        const r_type: u32 = @truncate(r_info & 0xFFFF_FFFF);
        if (r_type == 1) { // R_X86_64_64
            found_addr64 = true;
        }
    }
    try std.testing.expect(found_addr64);
}

test "object emission: function call between two functions (PE/COFF)" {
    var module = ir.Module.empty;
    defer module.deinit(std.testing.allocator);

    var builder = ir.Builder.init(std.testing.allocator, &module);
    const i32_ty = try builder.addIntType(true, 32);

    const callee = try builder.addFunction("callee", i32_ty, 1);
    builder.setCurrentFunction(callee);
    const c_entry = try builder.appendBlock();
    builder.setCurrentBlock(c_entry);
    const n = @as(ir.Value, @enumFromInt(0));
    _ = try builder.buildRet(n);

    const main = try builder.addFunction("main", i32_ty, 1);
    builder.setCurrentFunction(main);
    const m_entry = try builder.appendBlock();
    builder.setCurrentBlock(m_entry);
    const n2 = @as(ir.Value, @enumFromInt(0));
    _ = try builder.buildCall(callee, i32_ty, &[_]ir.Value{ n2 });
    const zero = try builder.buildIntConst(i32_ty, 0);
    _ = try builder.buildRet(zero);

    var cg = CodeGen.init(std.testing.allocator, &module);
    defer cg.deinit();
    const input = try cg.emitObjectModule();
    const pe_syms_ptr: [*]const obj_pe.Symbol = @ptrCast(input.symbols.ptr);
    const pe_syms = pe_syms_ptr[0..input.symbols.len];
    const pe_relocs_ptr: [*]const obj_pe.Reloc = @ptrCast(input.relocs.ptr);
    const pe_relocs = pe_relocs_ptr[0..input.relocs.len];
    const pe_input = obj_pe.ObjectInput{
        .text = input.text,
        .data = input.data,
        .bss_size = input.bss_size,
        .symbols = pe_syms,
        .relocs = pe_relocs,
    };

    var w = obj_pe.Writer.init(std.testing.allocator);
    defer w.deinit();
    const bytes = try w.writeObject(pe_input);
    defer std.testing.allocator.free(bytes);

    // COFF file header.
    try std.testing.expectEqual(0x8664, readU16(bytes, 0)); // machine = AMD64
    try std.testing.expectEqual(3, readU16(bytes, 2)); // 3 sections
    try std.testing.expectEqual(0x0001, readU16(bytes, 18)); // characteristics

    // Section table (40 bytes each, starting at 20): .text, .data, .bss.
    const sh_text_off = 20 + 0 * 40;
    try std.testing.expectEqual(obj_pe.ScnCntCode | obj_pe.ScnMemExecute | obj_pe.ScnMemRead,
        readU32(bytes, sh_text_off + 36));
    const text_size = readU32(bytes, sh_text_off + 16);
    try std.testing.expect(text_size > 0);
    const text_ptr = readU32(bytes, sh_text_off + 20);
    try std.testing.expectEqual(text_ptr, 20 + 40 * 3); // raw data after headers
    var found_ret = false;
    for (bytes[text_ptr..text_ptr + text_size]) |b| { if (b == 0xc3) found_ret = true; }
    try std.testing.expect(found_ret);

    const sh_data_off = 20 + 1 * 40;
    try std.testing.expectEqual(obj_pe.ScnCntInitializedData | obj_pe.ScnMemRead | obj_pe.ScnMemWrite,
        readU32(bytes, sh_data_off + 36));
    const sh_bss_off = 20 + 2 * 40;
    try std.testing.expectEqual(obj_pe.ScnCntUninitializedData | obj_pe.ScnMemRead | obj_pe.ScnMemWrite,
        readU32(bytes, sh_bss_off + 36));

    // .text relocation: PC32 (REL32 = 4) for _callee.
    const data_size = readU32(bytes, sh_data_off + 16);
    const reloc_start = text_ptr + text_size + data_size;
    try std.testing.expect(reloc_start < bytes.len);
    const r_type: u16 = @as(u16, bytes[reloc_start + 8]) | (@as(u16, bytes[reloc_start + 9]) << 8);
    try std.testing.expectEqual(obj_pe.CoffRelocRel32, r_type); // IMAGE_REL_AMD64_REL32
}

test "object emission: closure env + call_ptr (PE/COFF)" {
    var module = ir.Module.empty;
    defer module.deinit(std.testing.allocator);

    var builder = ir.Builder.init(std.testing.allocator, &module);
    const i64_ty = try builder.addIntType(true, 64);

    const lifted = try builder.addFunction("__closure_0", i64_ty, 2);
    builder.setCurrentFunction(lifted);
    const l_entry = try builder.appendBlock();
    builder.setCurrentBlock(l_entry);
    const env_param = @as(ir.Value, @enumFromInt(0));
    const x_param = @as(ir.Value, @enumFromInt(1));
    const captured = try builder.buildLoad(i64_ty, env_param);
    _ = try builder.buildRet(try builder.buildAdd(i64_ty, captured, x_param));

    const sig = try builder.addFunctionType(i64_ty, &.{i64_ty});
    const fv_ty = try builder.addFunctionValueType(sig);
    const caller = try builder.addFunction("caller", i64_ty, 1);
    builder.setCurrentFunction(caller);
    const c_entry = try builder.appendBlock();
    builder.setCurrentBlock(c_entry);
    const x_arg = @as(ir.Value, @enumFromInt(0));

    const fn_addr = try builder.buildFuncAddr(i64_ty, lifted);
    const forty = try builder.buildIntConst(i64_ty, 40);
    const env = try builder.buildEnvRecord(&.{.{ .type_idx = i64_ty, .value = forty }});
    const fv = try builder.buildFnValue(fv_ty, fn_addr, env);
    const result = try builder.buildCallPtr(i64_ty, fv, &.{x_arg});
    _ = try builder.buildRet(result);

    var cg = CodeGen.init(std.testing.allocator, &module);
    defer cg.deinit();
    const input = try cg.emitObjectModule();
    const pe_syms_ptr: [*]const obj_pe.Symbol = @ptrCast(input.symbols.ptr);
    const pe_syms = pe_syms_ptr[0..input.symbols.len];
    const pe_relocs_ptr: [*]const obj_pe.Reloc = @ptrCast(input.relocs.ptr);
    const pe_relocs = pe_relocs_ptr[0..input.relocs.len];
    const pe_input = obj_pe.ObjectInput{
        .text = input.text,
        .data = input.data,
        .bss_size = input.bss_size,
        .symbols = pe_syms,
        .relocs = pe_relocs,
    };

    var w = obj_pe.Writer.init(std.testing.allocator);
    defer w.deinit();
    const bytes = try w.writeObject(pe_input);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqual(0x8664, readU16(bytes, 0)); // machine = AMD64
    try std.testing.expectEqual(3, readU16(bytes, 2)); // 3 sections

    const sh_text_off = 20 + 0 * 40;
    const text_size = readU32(bytes, sh_text_off + 16);
    const text_ptr = readU32(bytes, sh_text_off + 20);
    const text_reloc_count = readU16(bytes, sh_text_off + 32); // number_of_relocations

    // Indirect call through the register: "call rax" = 0xff 0xd0.
    var found_call_rax = false;
    for (bytes[text_ptr..], 0..) |b, i| {
        if (i < text_size and i + 1 < text_size and b == 0xff and bytes[text_ptr + i + 1] == 0xd0) {
            found_call_rax = true;
        }
    }
    try std.testing.expect(found_call_rax);

    // ADDR64 relocation (type 1) present for the func_addr'd lifted function.
    const data_size = readU32(bytes, 20 + 1 * 40 + 16);
    const reloc_start = text_ptr + text_size + data_size;
    var found_addr64 = false;
    var r: u64 = 0;
    while (r < @as(u64, @intCast(text_reloc_count)) and reloc_start + r * 10 + 10 <= bytes.len) : (r += 1) {
        const r_type: u16 = @as(u16, bytes[reloc_start + r * 10 + 8]) | (@as(u16, bytes[reloc_start + r * 10 + 9]) << 8);
        if (r_type == obj_pe.CoffRelocAddr64) { // IMAGE_REL_AMD64_ADDR64
            found_addr64 = true;
        }
    }
    try std.testing.expect(found_addr64);
}

fn readU16(bytes: []const u8, off: usize) u16 {
    return @as(u16, bytes[off]) | (@as(u16, bytes[off + 1]) << 8);
}

fn readU32(bytes: []const u8, off: usize) u32 {
    return @as(u32, bytes[off])
        | (@as(u32, bytes[off + 1]) << 8)
        | (@as(u32, bytes[off + 2]) << 16)
        | (@as(u32, bytes[off + 3]) << 24);
}

fn readU64(bytes: []const u8, off: usize) u64 {
    var v: u64 = 0;
    var i: u6 = 0;
    while (i < 8) : (i += 1) {
        v |= @as(u64, bytes[off + @as(usize, i)]) << i * 8;
    }
    return v;
}

fn readI64(bytes: []const u8, off: usize) i64 {
    return @bitCast(readU64(bytes, off));
}
