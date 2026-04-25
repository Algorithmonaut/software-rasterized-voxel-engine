.intel_syntax noprefix

.section .rodata
.align 32

.Llanes_i32:
    .long 0, 1, 2, 3, 4, 5, 6, 7

.Llanes_f32:
    .float 0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0

.Lfloat8:
    .float 8.0


.text
.global raster_row_avx2
.type raster_row_avx2, @function

raster_row_avx2:
    push rbp
    mov rbp, rsp

    push rbx
    push r12
    push r13
    push r14
    push r15

    // Stack scratch:
    // [rsp +   0] inv_z[8]
    // [rsp +  32] den[8]
    // [rsp +  64] u_num[8]
    // [rsp +  96] v_num[8]
    sub rsp, 160

    mov r10, rdi                 // args

    mov r13, QWORD PTR [r10 + 0] // z_buf
    mov r14, QWORD PTR [r10 + 8] // out

    mov ebx, DWORD PTR [r10 + 20]    // current x
    mov r15d, ebx
    add r15d, DWORD PTR [r10 + 24]   // end x = x0 + x_count

    xor r12d, r12d               // fragment count

    cmp ebx, r15d
    jae .done

    // Load current edge starts.
    mov r8d,  DWORD PTR [r10 + 32]   // w0_cur
    mov r9d,  DWORD PTR [r10 + 36]   // w1_cur
    mov r11d, DWORD PTR [r10 + 40]   // w2_cur

    // Current scalar interpolants.
    vmovss xmm10, DWORD PTR [r10 + 56]   // den_cur
    vmovss xmm11, DWORD PTR [r10 + 60]   // u_cur
    vmovss xmm12, DWORD PTR [r10 + 64]   // v_cur

    // Constants.
    vmovdqa ymm15, YMMWORD PTR [rip + .Llanes_i32]
    vmovaps ymm13, YMMWORD PTR [rip + .Llanes_f32]

    // ymm14 = all bits set, also integer -1.
    vpcmpeqd ymm14, ymm14, ymm14

.loop8:
    // ------------------------------------------------------------
    // Edge coverage, 8 pixels.
    // wN = wN_cur + lane * wN_dx
    // inside if w0 >= 0 && w1 >= 0 && w2 >= 0
    // Since vpcmpgtd is ">", test w > -1.
    // ------------------------------------------------------------

    cmp DWORD PTR [r10 + 28], 0
    jne .full_cover

    // w0 vector
    vmovd xmm0, r8d
    vpbroadcastd ymm0, xmm0
    vpbroadcastd ymm1, DWORD PTR [r10 + 44]
    vpmulld ymm1, ymm1, ymm15
    vpaddd ymm0, ymm0, ymm1
    vpcmpgtd ymm4, ymm0, ymm14     // w0 > -1

    // w1 vector
    vmovd xmm0, r9d
    vpbroadcastd ymm0, xmm0
    vpbroadcastd ymm1, DWORD PTR [r10 + 48]
    vpmulld ymm1, ymm1, ymm15
    vpaddd ymm0, ymm0, ymm1
    vpcmpgtd ymm2, ymm0, ymm14     // w1 > -1
    vpand ymm4, ymm4, ymm2

    // w2 vector
    vmovd xmm0, r11d
    vpbroadcastd ymm0, xmm0
    vpbroadcastd ymm1, DWORD PTR [r10 + 52]
    vpmulld ymm1, ymm1, ymm15
    vpaddd ymm0, ymm0, ymm1
    vpcmpgtd ymm2, ymm0, ymm14     // w2 > -1
    vpand ymm4, ymm4, ymm2

    jmp .coverage_ready

.full_cover:
    vmovdqa ymm4, ymm14            // coverage mask = all lanes enabled

.coverage_ready:
    // Quick reject if coverage mask is empty.
    vmovmskps edx, ymm4
    test edx, edx
    jz .advance

    // ------------------------------------------------------------
    // Interpolants.
    // den   = den_cur + lane * den_dx
    // u_num = u_cur   + lane * u_dx
    // v_num = v_cur   + lane * v_dx
    // inv_z = den * inv_area
    // ------------------------------------------------------------

    // den vector -> ymm5
    vbroadcastss ymm5, xmm10
    vbroadcastss ymm0, DWORD PTR [r10 + 68]
    vmulps ymm0, ymm0, ymm13
    vaddps ymm5, ymm5, ymm0

    // u vector -> ymm6
    vbroadcastss ymm6, xmm11
    vbroadcastss ymm0, DWORD PTR [r10 + 72]
    vmulps ymm0, ymm0, ymm13
    vaddps ymm6, ymm6, ymm0

    // v vector -> ymm7
    vbroadcastss ymm7, xmm12
    vbroadcastss ymm0, DWORD PTR [r10 + 76]
    vmulps ymm0, ymm0, ymm13
    vaddps ymm7, ymm7, ymm0

    // inv_z -> ymm8
    vbroadcastss ymm0, DWORD PTR [r10 + 80]
    vmulps ymm8, ymm5, ymm0

    // ------------------------------------------------------------
    // Z-test.
    // idx = row_base + x
    // pass if inv_z > z_buf[idx]
    // ------------------------------------------------------------

    mov eax, DWORD PTR [r10 + 16]   // row_base
    add eax, ebx                    // row_base + x

    vmovups ymm0, YMMWORD PTR [r13 + rax*4]    // old z

    // 0x1e = ordered quiet greater-than.
    vcmpps ymm1, ymm8, ymm0, 0x1e              // inv_z > old_z

    // combine with coverage
    vpand ymm1, ymm1, ymm4

    vmovmskps edx, ymm1
    test edx, edx
    jz .advance

    // Masked z write.
    vmaskmovps YMMWORD PTR [r13 + rax*4], ymm1, ymm8

    // Spill vectors for scalar fragment emission.
    vmovups YMMWORD PTR [rsp + 0],  ymm8       // inv_z
    vmovups YMMWORD PTR [rsp + 32], ymm5       // den
    vmovups YMMWORD PTR [rsp + 64], ymm6       // u_num
    vmovups YMMWORD PTR [rsp + 96], ymm7       // v_num

.emit_loop:
    bsf ecx, edx                    // lane index in ecx

    // Fragment pointer:
    //   out + fragment_count * sizeof(RasterFragment)
    // sizeof(RasterFragment) = 20
    mov eax, r12d
    lea rdi, [rax + rax*4]          // count * 5
    lea rdi, [r14 + rdi*4]          // out + count * 20

    // fragment.idx = row_base + x + lane
    mov eax, DWORD PTR [r10 + 16]
    add eax, ebx
    add eax, ecx
    mov DWORD PTR [rdi + 0], eax

    // fragment.inv_z
    movss xmm0, DWORD PTR [rsp + rcx*4 + 0]
    movss DWORD PTR [rdi + 4], xmm0

    // fragment.den
    movss xmm0, DWORD PTR [rsp + rcx*4 + 32]
    movss DWORD PTR [rdi + 8], xmm0

    // fragment.u_num
    movss xmm0, DWORD PTR [rsp + rcx*4 + 64]
    movss DWORD PTR [rdi + 12], xmm0

    // fragment.v_num
    movss xmm0, DWORD PTR [rsp + rcx*4 + 96]
    movss DWORD PTR [rdi + 16], xmm0

    inc r12d

    // Clear emitted bit.
    btr edx, ecx
    test edx, edx
    jnz .emit_loop

.advance:
    // Advance x by 8.
    add ebx, 8

    // Advance edge starts by dx * 8.
    mov eax, DWORD PTR [r10 + 44]
    shl eax, 3
    add r8d, eax

    mov eax, DWORD PTR [r10 + 48]
    shl eax, 3
    add r9d, eax

    mov eax, DWORD PTR [r10 + 52]
    shl eax, 3
    add r11d, eax

    // Advance scalar den/u/v by dx * 8.
    vmovss xmm0, DWORD PTR [r10 + 68]
    vmulss xmm0, xmm0, DWORD PTR [rip + .Lfloat8]
    vaddss xmm10, xmm10, xmm0

    vmovss xmm0, DWORD PTR [r10 + 72]
    vmulss xmm0, xmm0, DWORD PTR [rip + .Lfloat8]
    vaddss xmm11, xmm11, xmm0

    vmovss xmm0, DWORD PTR [r10 + 76]
    vmulss xmm0, xmm0, DWORD PTR [rip + .Lfloat8]
    vaddss xmm12, xmm12, xmm0

    cmp ebx, r15d
    jb .loop8

.done:
    mov eax, r12d

    vzeroupper

    add rsp, 160

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret
