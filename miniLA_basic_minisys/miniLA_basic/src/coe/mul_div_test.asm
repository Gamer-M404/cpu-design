.text
MAIN:
    lu12i.w $a7, 0xFFFF
    ori     $a7, $a7, 0x100
    slli.w  $a7, $a7, 4

    # test0
    lu12i.w $t0, 0x40000
    addi.w  $t0, $t0, 0x7B
    addi.w  $t1, $zero, 0x165
    mul.w   $a0, $t0, $t1       # 0x4000_007B*0x165 = 0x59_4000_AB87
    st.w    $a0, $a7, 0
    mulh.w  $a0, $t0, $t1       # 0x59
    st.w    $a0, $a7, 0
    mulh.wu $a0, $t0, $t1       # 0x59
    st.w    $a0, $a7, 0
    div.w   $a0, $t0, $t1       # 0x4000_007B/0x165 = 0x2D_E4C0
    st.w    $a0, $a7, 0
    mod.w   $a0, $t0, $t1       # 0x4000_007B%0x165 = 0xBB
    st.w    $a0, $a7, 0
    div.wu  $a0, $t0, $t1       # 0x2D_E4C0
    st.w    $a0, $a7, 0
    mod.wu  $a0, $t0, $t1       # 0xBB
    st.w    $a0, $a7, 0

    # test1
    addi.w  $t0, $zero, -26
    addi.w  $t1, $zero, 5
    mul.w   $a0, $t0, $t1       # -26*5 = 0xFFFF_FF7E
    st.w    $a0, $a7, 0
    mulh.w  $a0, $t0, $t1       # 0xFFFF_FFFF
    st.w    $a0, $a7, 0
    mulh.wu $a0, $t0, $t1       # 0x4
    st.w    $a0, $a7, 0
    div.w   $a0, $t0, $t1       # -26/5 = 0xFFFF_FFFB
    st.w    $a0, $a7, 0
    mod.w   $a0, $t0, $t1       # -26%5 = 0xFFFF_FFFF
    st.w    $a0, $a7, 0
    div.wu  $a0, $t0, $t1       # 0x3333_332E
    st.w    $a0, $a7, 0
    mod.wu  $a0, $t0, $t1       # 0x0
    st.w    $a0, $a7, 0

    # test2
    lu12i.w $t0, 0x45670
    addi.w  $t0, $t0, 0x64
    addi.w  $t1, $zero, -13
    mul.w   $a0, $t0, $t1       # 0x4567_0064*(-13) = 0xFFFF_FFFC_79C4_FAEC
    st.w    $a0, $a7, 0
    mulh.w  $a0, $t0, $t1       # 0xFFFF_FFFC
    st.w    $a0, $a7, 0
    mulh.wu $a0, $t0, $t1       # 4567_0060
    st.w    $a0, $a7, 0
    div.w   $a0, $t0, $t1       # 0x4567_0064/(-13) = 0xFAA9_4EBE
    st.w    $a0, $a7, 0
    mod.w   $a0, $t0, $t1       # 0x4567_0064%(-13) = 0xA
    st.w    $a0, $a7, 0
    div.wu  $a0, $t0, $t1       # 0x0
    st.w    $a0, $a7, 0
    mod.wu  $a0, $t0, $t1       # 0x4567_0064
    st.w    $a0, $a7, 0

    # test3
    addi.w  $t0, $zero, -306
    addi.w  $t1, $zero, -28
    mul.w   $a0, $t0, $t1       # (-306)*(-28) = 0x2178
    st.w    $a0, $a7, 0
    mulh.w  $a0, $t0, $t1       # 0x0
    st.w    $a0, $a7, 0
    mulh.wu $a0, $t0, $t1       # 0xFFFF_FEB2
    st.w    $a0, $a7, 0
    div.w   $a0, $t0, $t1       # (-306)/(-28) = 0xA
    st.w    $a0, $a7, 0
    mod.w   $a0, $t0, $t1       # (-306)%(-28) = 0xFFFF_FFE6
    st.w    $a0, $a7, 0
    div.wu  $a0, $t0, $t1       # 0x0
    st.w    $a0, $a7, 0
    mod.wu  $a0, $t0, $t1       # 0xFFFF_FECE
    st.w    $a0, $a7, 0
    
END_LOOP:
    addi.w  $zero, $zero, 0
    b       END_LOOP
