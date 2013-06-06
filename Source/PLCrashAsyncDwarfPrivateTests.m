/*
 * Author: Landon Fuller <landonf@plausible.coop>
 *
 * Copyright (c) 2012-2013 Plausible Labs Cooperative, Inc.
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation
 * files (the "Software"), to deal in the Software without
 * restriction, including without limitation the rights to use,
 * copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following
 * conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 * OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 */

#import "PLCrashTestCase.h"

#include "PLCrashAsyncDwarfEncoding.h"
#include "PLCrashAsyncDwarfPrivate.h"

struct __attribute__((packed)) cie_data {
    struct __attribute__((packed)) {
        uint32_t l1;
        uint64_t l2;
    } length;
    
    uint64_t cie_id;
    uint8_t cie_version;
    
    uint8_t augmentation[7];
    
    uint8_t address_size;
    uint8_t segment_size;
    
    uint8_t code_alignment_factor;
    uint8_t data_alignment_factor;
    uint8_t return_address_register;
    
    uint8_t augmentation_data[6];
    
    uint8_t initial_instructions[0];
};

@interface PLCrashAsyncDwarfPrivateTests : PLCrashTestCase {
    struct cie_data _cie_data;
    plcrash_async_dwarf_gnueh_ptr_state_t _ptr_state;
}@end

@implementation PLCrashAsyncDwarfPrivateTests

- (void) setUp {
    /* Set up the default pointer decode state. */
    plcrash_async_dwarf_gnueh_ptr_state_init(&_ptr_state, 8);

    /* Set up default CIE data */
    _cie_data.length.l1 = UINT32_MAX; /* 64-bit entry flag */
    _cie_data.length.l2 = sizeof(_cie_data) - sizeof(_cie_data.length);

    _cie_data.cie_id = 0x0;
    _cie_data.cie_version = 4;

    _cie_data.augmentation[0] = 'z';
    _cie_data.augmentation[1] = 'L'; // LSDA encoding
    _cie_data.augmentation[2] = 'P'; // Personality encoding
    _cie_data.augmentation[3] = 'R'; // FDE address encoding
    _cie_data.augmentation[4] = 'S'; // Signal frame
    _cie_data.augmentation[5] = 'b'; // known-bad augmentation flag; used to test termination of parsing
    _cie_data.augmentation[6] = '\0';
    
    
    /* NOTE: This is a ULEB128 value, and thus will fail if it's not representable in the first 7 bits */
    _cie_data.augmentation_data[0] = sizeof(_cie_data.augmentation_data);
    STAssertEquals((uint8_t)(_cie_data.augmentation_data[0] & 0x7f), _cie_data.augmentation_data[0], @"ULEB128 encoding will not fit in the available byte");
    
    _cie_data.augmentation_data[1] = DW_EH_PE_udata4; // LSDA encoding
    _cie_data.augmentation_data[2] = DW_EH_PE_udata2; // Personality pointer encoding
    _cie_data.augmentation_data[3] = 0xAA; // Personality udata2 pointer data
    _cie_data.augmentation_data[4] = 0xAA; // Personality udata2 pointer data
    _cie_data.augmentation_data[5] = DW_EH_PE_udata8; // FDE address pointer encoding.

    _cie_data.address_size = 4;
    _cie_data.segment_size = 4;

    _cie_data.code_alignment_factor = 1;
    _cie_data.data_alignment_factor = 2;
    _cie_data.return_address_register = 3;
}

- (void) tearDown {
    plcrash_async_dwarf_gnueh_ptr_state_free(&_ptr_state);
}

/**
 * Test default (standard path, no error) CIE parsing
 */
- (void) testParseCIE {
    plcrash_async_dwarf_cie_info_t cie;
    plcrash_async_mobject_t mobj;
    plcrash_error_t err;
    
    err = plcrash_async_mobject_init(&mobj, mach_task_self(), &_cie_data, sizeof(_cie_data), true);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to initialize mobj");


    /* Try to parse the CIE */
    err = plcrash_async_dwarf_cie_info_init(&cie, &mobj, &plcrash_async_byteorder_direct, &_ptr_state, &_cie_data);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to initialize CIE info");
    STAssertEquals(cie.cie_offset, (pl_vm_address_t)sizeof(_cie_data.length), @"Incorrect offset");
    STAssertEquals(cie.cie_length, (pl_vm_address_t) sizeof(_cie_data) - sizeof(_cie_data.length), @"Incorrect length");
    
    /* Test basics */
    STAssertEquals(cie.cie_id, _cie_data.cie_id, @"Incorrect ID");
    STAssertEquals(cie.cie_version, _cie_data.cie_version, @"Incorrect version");
    
    /* DWARF4 fields */
    STAssertEquals(cie.address_size, _cie_data.address_size, @"Incorrect address size");
    STAssertEquals(cie.segment_size, _cie_data.segment_size, @"Incorrect segment size");

    /* Alignment and return address fields */
    STAssertEquals(cie.code_alignment_factor, (uint64_t)_cie_data.code_alignment_factor, @"Incorrect code alignment factor");
    STAssertEquals(cie.data_alignment_factor, (int64_t)_cie_data.data_alignment_factor, @"Incorrect data alignment factor");
    STAssertEquals(cie.return_address_register, (uint64_t)_cie_data.return_address_register, @"Incorrect return address register");
    
    /* Augmentation handling */
    STAssertTrue(cie.has_eh_augmentation, @"No augmentation data was found");

    STAssertTrue(cie.eh_augmentation.has_lsda_encoding, @"No LSDA data was found");
    STAssertEquals(cie.eh_augmentation.lsda_encoding, (uint8_t)DW_EH_PE_udata4, @"Incorrect LSDA encoding");
    
    STAssertTrue(cie.eh_augmentation.has_personality_address, @"No personality data was found");
    STAssertEquals(cie.eh_augmentation.personality_address, (uint64_t)0xAAAA, @"Incorrect personality address");
    
    STAssertTrue(cie.eh_augmentation.has_pointer_encoding, @"No pointer encoding was found");
    STAssertEquals(cie.eh_augmentation.pointer_encoding, (uint8_t)DW_EH_PE_udata8, @"Incorrect pointer encoding");
    
    STAssertTrue(cie.eh_augmentation.signal_frame, @"Did not parse signal frame flag");

    /* Instructions */
    STAssertEquals(cie.initial_instructions_offset, ((pl_vm_address_t)_cie_data.initial_instructions) - (pl_vm_address_t) &_cie_data, @"Incorrect initial instruction offset");

    /* Clean up */
    plcrash_async_dwarf_cie_info_free(&cie);
    plcrash_async_mobject_free(&mobj);
}

/**
 * Test parsing of a CIE entry with an unknown augmentation string
 */
- (void) testParseCIEBadAugmentation {
    plcrash_async_dwarf_cie_info_t cie;
    plcrash_async_mobject_t mobj;
    plcrash_error_t err;
    
    _cie_data.augmentation[0] = 'P';
    err = plcrash_async_mobject_init(&mobj, mach_task_self(), &_cie_data, sizeof(_cie_data), true);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to initialize mobj");
    
    /* Try to parse the CIE, verify failure */
    err = plcrash_async_dwarf_cie_info_init(&cie, &mobj, &plcrash_async_byteorder_direct, &_ptr_state, &_cie_data);
    STAssertNotEquals(err, PLCRASH_ESUCCESS, @"Failed to initialize CIE info");
    
    /* Clean up */
    plcrash_async_dwarf_cie_info_free(&cie);
    plcrash_async_mobject_free(&mobj);
}

/**
 * Test parsing of a CIE entry with a bad identifier.
 */
- (void) testParseCIEBadIdentifier {
    plcrash_async_dwarf_cie_info_t cie;
    plcrash_async_mobject_t mobj;
    plcrash_error_t err;

    _cie_data.cie_id = 5; // invalid id
    err = plcrash_async_mobject_init(&mobj, mach_task_self(), &_cie_data, sizeof(_cie_data), true);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to initialize mobj");
    
    /* Try to parse the CIE, verify failure */
    err = plcrash_async_dwarf_cie_info_init(&cie, &mobj, &plcrash_async_byteorder_direct, &_ptr_state, &_cie_data);
    STAssertNotEquals(err, PLCRASH_ESUCCESS, @"Failed to initialize CIE info");
    
    /* Clean up */
    plcrash_async_dwarf_cie_info_free(&cie);
    plcrash_async_mobject_free(&mobj);
}

/**
 * Test parsing of a CIE entry with a bad version.
 */
- (void) testParseCIEBadVersion {
    plcrash_async_dwarf_cie_info_t cie;
    plcrash_async_mobject_t mobj;
    plcrash_error_t err;
    
    _cie_data.cie_version = 9999; // invalid version
    err = plcrash_async_mobject_init(&mobj, mach_task_self(), &_cie_data, sizeof(_cie_data), true);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to initialize mobj");
    
    /* Try to parse the CIE, verify failure */
    err = plcrash_async_dwarf_cie_info_init(&cie, &mobj, &plcrash_async_byteorder_direct, &_ptr_state, &_cie_data);
    STAssertNotEquals(err, PLCRASH_ESUCCESS, @"Failed to initialize CIE info");
    
    /* Clean up */
    plcrash_async_dwarf_cie_info_free(&cie);
    plcrash_async_mobject_free(&mobj);
}

/**
 * Test aligned pointer decoding
 */
- (void) testReadAlignedEncodedPointer {
    plcrash_async_mobject_t mobj;
    plcrash_async_dwarf_gnueh_ptr_state_t state;
    plcrash_error_t err;
    pl_vm_address_t result;
    pl_vm_size_t size;
    
    /* Test data */
    const uint8_t aligned_data[] = { 0xaa, 0xab, 0xac, 0xad, 0xae, 0xaf, 0xba, 0xbb };
    
    /* Default state */
    plcrash_async_dwarf_gnueh_ptr_state_init(&state, sizeof(uint32_t));
    plcrash_async_dwarf_gnueh_ptr_state_set_frame_section_base(&state, aligned_data, aligned_data-1);

    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), aligned_data, sizeof(aligned_data), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_gnueh_ptr(&mobj, plcrash_async_byteorder_big_endian(), &aligned_data[0], 0, DW_EH_PE_aligned, &state, &result, &size);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode aligned value");
    
    /* The VM base is 1 byte shy of four byte alignment. To align the pointer value, we'll have to skip 3 bytes. */
    STAssertEquals(result, (pl_vm_address_t) 0xadaeafba, @"Incorrect value decoded, got 0%" PRIx32, (uint32_t) result);
    STAssertEquals(size, (pl_vm_size_t)7, @"Incorrect byte length");
    
    plcrash_async_mobject_free(&mobj);
}

/**
 * Test indirect pointer handling.
 */
- (void) testReadIndirectEncodedPointer {
    plcrash_async_mobject_t mobj;
    plcrash_async_dwarf_gnueh_ptr_state_t state;
    plcrash_error_t err;
    pl_vm_address_t result;
    pl_vm_size_t size;
    
    /* Test data */
    struct {
        uint64_t udata8;
        uint64_t ptr;
    } test_data;
    test_data.udata8 = &test_data.ptr;
    test_data.ptr = UINT32_MAX;
    
    plcrash_async_dwarf_gnueh_ptr_state_init(&state, sizeof(uint64_t));
    
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), &test_data, sizeof(test_data), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_gnueh_ptr(&mobj, &plcrash_async_byteorder_direct, &test_data.udata8, 0, DW_EH_PE_indirect|DW_EH_PE_udata8, &state, &result, &size);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode aligned value");
    
    STAssertEquals(result, (pl_vm_address_t) test_data.ptr, @"Incorrect value decoded, got 0%" PRIx32, (uint32_t) result);
    STAssertEquals(size, (pl_vm_size_t)8, @"Incorrect byte length");
    
    plcrash_async_mobject_free(&mobj);
}

/**
 * Test pointer offset type handling
 */
- (void) testReadEncodedPointerOffset {
    plcrash_async_mobject_t mobj;
    plcrash_async_dwarf_gnueh_ptr_state_t state;
    plcrash_error_t err;
    pl_vm_address_t result;
    pl_vm_size_t size;
    
    /* Test data */
    union {
        uint64_t udata8;
    } test_data;
    
    /* Default state */
#define T_TEXT_BASE 1
#define T_DATA_BASE 2
#define T_FUNC_BASE 3
    plcrash_async_dwarf_gnueh_ptr_state_init(&state, sizeof(uint64_t));
    plcrash_async_dwarf_gnueh_ptr_state_set_pc_rel_base(&state, &test_data);
    plcrash_async_dwarf_gnueh_ptr_state_set_text_base(&state, T_TEXT_BASE);
    plcrash_async_dwarf_gnueh_ptr_state_set_data_base(&state, T_DATA_BASE);
    plcrash_async_dwarf_gnueh_ptr_state_set_func_base(&state, T_FUNC_BASE);
    
    /* Test absptr */
    test_data.udata8 = UINT64_MAX;
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), &test_data, sizeof(test_data), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_gnueh_ptr(&mobj, &plcrash_async_byteorder_direct, &test_data, 0, DW_EH_PE_absptr, &state, &result, &size);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode uleb128");
    STAssertEquals(result, (pl_vm_address_t)UINT64_MAX, @"Incorrect value decoded");
    STAssertEquals(size, (pl_vm_size_t)8, @"Incorrect byte length");
    plcrash_async_mobject_free(&mobj);
    
    /* Test pcrel */
    test_data.udata8 = 5;
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), &test_data, sizeof(test_data), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_gnueh_ptr(&mobj, &plcrash_async_byteorder_direct, &test_data, 0, DW_EH_PE_pcrel, &state, &result, &size);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode pcrel value");
    STAssertEquals(result, (pl_vm_address_t)&test_data + 5, @"Incorrect value decoded");
    STAssertEquals(size, (pl_vm_size_t)8, @"Incorrect byte length");
    plcrash_async_mobject_free(&mobj);
    
    /* Test textrel */
    test_data.udata8 = 5;
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), &test_data, sizeof(test_data), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_gnueh_ptr(&mobj, &plcrash_async_byteorder_direct, &test_data, 0, DW_EH_PE_textrel, &state, &result, &size);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode textrel value");
    STAssertEquals(result, (pl_vm_address_t)test_data.udata8+T_TEXT_BASE, @"Incorrect value decoded");
    STAssertEquals(size, (pl_vm_size_t)8, @"Incorrect byte length");
    plcrash_async_mobject_free(&mobj);
    
    /* Test datarel */
    test_data.udata8 = 5;
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), &test_data, sizeof(test_data), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_gnueh_ptr(&mobj, &plcrash_async_byteorder_direct, &test_data, 0, DW_EH_PE_datarel, &state, &result, &size);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode datarel value");
    STAssertEquals(result, (pl_vm_address_t)test_data.udata8+T_DATA_BASE, @"Incorrect value decoded");
    STAssertEquals(size, (pl_vm_size_t)8, @"Incorrect byte length");
    plcrash_async_mobject_free(&mobj);
    
    /* Test funcrel */
    test_data.udata8 = 5;
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), &test_data, sizeof(test_data), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_gnueh_ptr(&mobj, &plcrash_async_byteorder_direct, &test_data, 0, DW_EH_PE_funcrel, &state, &result, &size);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode funcrel value");
    STAssertEquals(result, (pl_vm_address_t)test_data.udata8+T_FUNC_BASE, @"Incorrect value decoded");
    STAssertEquals(size, (pl_vm_size_t)8, @"Incorrect byte length");
    plcrash_async_mobject_free(&mobj);
}

/**
 * Test pointer value type decoding.
 */
- (void) testReadEncodedPointerValue {
    plcrash_async_mobject_t mobj;
    plcrash_async_dwarf_gnueh_ptr_state_t state;
    plcrash_error_t err;
    pl_vm_address_t result;
    pl_vm_size_t size;
    
    /* Test data */
    union {
        uint8_t leb128[2];
        
        uint16_t udata2;
        uint32_t udata4;
        uint64_t udata8;
        
        int16_t sdata2;
        int16_t sdata4;
        int16_t sdata8;
    } test_data;
    
    /* Default state */
    plcrash_async_dwarf_gnueh_ptr_state_init(&state, sizeof(uint64_t));
    plcrash_async_dwarf_gnueh_ptr_state_set_pc_rel_base(&state, &test_data);
    
    /* We use an -1 +1 offset below to verify the address+offset handling for all data types */
    
    /* Test ULEB128 */
    test_data.leb128[0] = 2;
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), &test_data, sizeof(test_data), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_gnueh_ptr(&mobj, &plcrash_async_byteorder_direct, (pl_vm_address_t)&test_data-1, 1, DW_EH_PE_uleb128, &state, &result, &size);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode uleb128");
    STAssertEquals(result, (pl_vm_address_t)2, @"Incorrect value decoded");
    STAssertEquals(size, (pl_vm_size_t)1, @"Incorrect byte length");
    
    plcrash_async_mobject_free(&mobj);
    
    /* Test udata2 */
    test_data.udata2 = UINT16_MAX;
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), &test_data, sizeof(test_data), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_gnueh_ptr(&mobj, &plcrash_async_byteorder_direct, (pl_vm_address_t)&test_data-1, 1, DW_EH_PE_udata2, &state, &result, &size);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode udata2");
    STAssertEquals(result, (pl_vm_address_t)UINT16_MAX, @"Incorrect value decoded");
    STAssertEquals(size, (pl_vm_size_t)2, @"Incorrect byte length");
    
    plcrash_async_mobject_free(&mobj);
    
    /* Test udata4 */
    test_data.udata4 = UINT32_MAX;
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), &test_data, sizeof(test_data), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_gnueh_ptr(&mobj, &plcrash_async_byteorder_direct, (pl_vm_address_t)&test_data-1, 1, DW_EH_PE_udata4, &state, &result, &size);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode udata4");
    STAssertEquals(result, (pl_vm_address_t)UINT32_MAX, @"Incorrect value decoded");
    STAssertEquals(size, (pl_vm_size_t)4, @"Incorrect byte length");
    
    plcrash_async_mobject_free(&mobj);
    
    /* Test udata8 */
    test_data.udata8 = UINT64_MAX;
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), &test_data, sizeof(test_data), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_gnueh_ptr(&mobj, &plcrash_async_byteorder_direct, (pl_vm_address_t)&test_data-1, 1, DW_EH_PE_udata8, &state, &result, &size);
    if (PL_VM_ADDRESS_MAX >= UINT64_MAX) {
        STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode udata8");
        STAssertEquals(result, (pl_vm_address_t)UINT64_MAX, @"Incorrect value decoded");
        STAssertEquals(size, (pl_vm_size_t)8, @"Incorrect byte length");
    } else {
        STAssertEquals(err, PLCRASH_EINVAL, @"Decoding should have failed");
    }
    
    /* Test SLEB128 (including pcrel validation to ensure that signed values are handled as offsets) */
    test_data.leb128[0] = 0x7e; // -2
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), &test_data, sizeof(test_data), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_gnueh_ptr(&mobj, &plcrash_async_byteorder_direct, (pl_vm_address_t)&test_data-1, 1, DW_EH_PE_pcrel|DW_EH_PE_sleb128, &state, &result, &size);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode sleb128");
    STAssertEquals(result, ((pl_vm_address_t) &test_data) - 2, @"Incorrect value decoded");
    STAssertEquals(size, (pl_vm_size_t)1, @"Incorrect byte length");
    
    plcrash_async_mobject_free(&mobj);
    
    /* Test sdata2 (including pcrel validation) */
    test_data.sdata2 = -256;
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), &test_data, sizeof(test_data), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_gnueh_ptr(&mobj, &plcrash_async_byteorder_direct, (pl_vm_address_t)&test_data-1, 1, DW_EH_PE_pcrel|DW_EH_PE_sdata2, &state, &result, &size);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode udata2");
    STAssertEquals(result, ((pl_vm_address_t) &test_data) - 256, @"Incorrect value decoded");
    STAssertEquals(size, (pl_vm_size_t)2, @"Incorrect byte length");
    
    plcrash_async_mobject_free(&mobj);
    
    /* Test sdata4 (including pcrel validation) */
    test_data.sdata4 = -256;
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), &test_data, sizeof(test_data), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_gnueh_ptr(&mobj, &plcrash_async_byteorder_direct, (pl_vm_address_t)&test_data-1, 1, DW_EH_PE_pcrel|DW_EH_PE_sdata4, &state, &result, &size);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode sdata4");
    STAssertEquals(result, ((pl_vm_address_t) &test_data) - 256, @"Incorrect value decoded");
    STAssertEquals(size, (pl_vm_size_t)4, @"Incorrect byte length");
    
    plcrash_async_mobject_free(&mobj);
    
    /* Test sdata8 (including pcrel validation) */
    test_data.sdata8 = -256;
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), &test_data, sizeof(test_data), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_gnueh_ptr(&mobj, &plcrash_async_byteorder_direct, (pl_vm_address_t)&test_data-1, 1, DW_EH_PE_pcrel|DW_EH_PE_sdata8, &state, &result, &size);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode udata8");
    STAssertEquals(result, ((pl_vm_address_t) &test_data) - 256, @"Incorrect value decoded");
    STAssertEquals(size, (pl_vm_size_t)8, @"Incorrect byte length");
    
    plcrash_async_mobject_free(&mobj);
}

/**
 * Test ULEB128 parsing.
 */
- (void) testReadULEB128 {
    /* Configure test */
    uint8_t buffer[11];
    plcrash_async_mobject_t mobj;
    plcrash_error_t err;
    uint64_t result;
    pl_vm_size_t size;
    
    /* Test offset handling */
    buffer[0] = 2;
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), buffer, sizeof(buffer), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_uleb128(&mobj, buffer+1, -1, &result, &size);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode uleb128");
    STAssertEquals(result, (uint64_t)2, @"Incorrect value decoded");
    STAssertEquals(size, (pl_vm_size_t)1, @"Incorrect byte length");
    plcrash_async_mobject_free(&mobj);

    /* Test a single byte */
    buffer[0] = 2;
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), buffer, sizeof(buffer), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_uleb128(&mobj, buffer, 0, &result, &size);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode uleb128");
    STAssertEquals(result, (uint64_t)2, @"Incorrect value decoded");
    STAssertEquals(size, (pl_vm_size_t)1, @"Incorrect byte length");
    plcrash_async_mobject_free(&mobj);
    
    /* Test multi-byte */
    buffer[0] = 0+0x80;
    buffer[1] = 1;
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), buffer, sizeof(buffer), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_uleb128(&mobj, buffer, 0, &result, &size);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode uleb128");
    STAssertEquals(result, (uint64_t)128, @"Incorrect value decoded");
    STAssertEquals(size, (pl_vm_size_t)2, @"Incorrect byte length");
    plcrash_async_mobject_free(&mobj);
    
    /* Test UINT64_MAX */
    memset(buffer, 0xFF, sizeof(buffer));
    buffer[9] = 0x7F;
    
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), buffer, sizeof(buffer), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_uleb128(&mobj, buffer, 0, &result, &size);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode uleb128");
    STAssertEquals(result, (uint64_t)UINT64_MAX, @"Incorrect value decoded");
    STAssertEquals(size, (pl_vm_size_t)10, @"Incorrect byte length");
    plcrash_async_mobject_free(&mobj);
    
    /* Test handling of an integer larger than 64 bits. */
    memset(buffer, 0x80, sizeof(buffer));
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), buffer, sizeof(buffer), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_uleb128(&mobj, buffer, 0, &result, &size);
    STAssertEquals(err, PLCRASH_ENOTSUP, @"ULEB128 should not be decodable");
    plcrash_async_mobject_free(&mobj);
    
    /* Test end-of-buffer handling */
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), buffer, 1, true), @"Failed to initialize mobj mapping");
    buffer[0] = 1+0x80;
    err = plcrash_async_dwarf_read_uleb128(&mobj, buffer, 0, &result, &size);
    STAssertEquals(err, PLCRASH_EINVAL, @"ULEB128 should not be decodable");
    plcrash_async_mobject_free(&mobj);
}

/**
 * Test uintmax64 reading.
 */
- (void) testReadUintMax64 {
    plcrash_async_mobject_t mobj;
    plcrash_error_t err;
    uint64_t result;

    /* Test data */
    union {
        uint8_t udata1;
        uint16_t udata2;
        uint32_t udata4;
        uint64_t udata8;
    } test_data;
    
    /* uint8_t */
    test_data.udata1 = UINT8_MAX;
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), &test_data, sizeof(test_data), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_uintmax64(&mobj, &plcrash_async_byteorder_direct, ((pl_vm_address_t)&test_data)-1, 1, 1, &result);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode uint8_t");
    STAssertEquals(result, (uint64_t)UINT8_MAX, @"Incorrect value decoded");

    plcrash_async_mobject_free(&mobj);
    
    /* uint16_t */
    test_data.udata2 = UINT16_MAX;
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), &test_data, sizeof(test_data), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_uintmax64(&mobj, &plcrash_async_byteorder_direct, ((pl_vm_address_t)&test_data)-1, 1, 2, &result);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode uint16_t");
    STAssertEquals(result, (uint64_t)UINT16_MAX, @"Incorrect value decoded");
    plcrash_async_mobject_free(&mobj);

    /* uint32_t */
    test_data.udata4 = UINT32_MAX;
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), &test_data, sizeof(test_data), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_uintmax64(&mobj, &plcrash_async_byteorder_direct, ((pl_vm_address_t)&test_data)-1, 1, 4, &result);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode uint32_t");
    STAssertEquals(result, (uint64_t)UINT32_MAX, @"Incorrect value decoded");
    plcrash_async_mobject_free(&mobj);
    
    /* uint64_t */
    test_data.udata8 = UINT64_MAX;
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), &test_data, sizeof(test_data), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_uintmax64(&mobj, &plcrash_async_byteorder_direct, ((pl_vm_address_t)&test_data)-1, 1, 8, &result);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode uint64_t");
    STAssertEquals(result, (uint64_t)UINT64_MAX, @"Incorrect value decoded");
    plcrash_async_mobject_free(&mobj);
    
    /* Invalid size */
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), &test_data, sizeof(test_data), true), @"Failed to initialize mobj mapping");
    err = plcrash_async_dwarf_read_uintmax64(&mobj, &plcrash_async_byteorder_direct, ((pl_vm_address_t)&test_data)-1, 1, 3, &result);
    STAssertNotEquals(err, PLCRASH_ESUCCESS, @"Expected error with invalid byte size of 3");
    
    plcrash_async_mobject_free(&mobj);
    
}

/**
 * Test SLEB128 parsing.
 */
- (void) testReadSLEB128 {
    /* Configure test */
    uint8_t buffer[11];
    plcrash_async_mobject_t mobj;
    plcrash_error_t err;
    int64_t result;
    pl_vm_size_t size;
    
    /* Test offset handling */
    buffer[0] = 2;
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), buffer, sizeof(buffer), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_sleb128(&mobj, buffer+1, -1, &result, &size);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode sleb128");
    STAssertEquals(result, (int64_t)2, @"Incorrect value decoded");
    STAssertEquals(size, (pl_vm_size_t)1, @"Incorrect byte length");
    plcrash_async_mobject_free(&mobj);
    
    /* Test a single byte */
    buffer[0] = 2;
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), buffer, sizeof(buffer), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_sleb128(&mobj, buffer, 0, &result, &size);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode sleb128");
    STAssertEquals(result, (int64_t)2, @"Incorrect value decoded");
    STAssertEquals(size, (pl_vm_size_t)1, @"Incorrect byte length");
    plcrash_async_mobject_free(&mobj);
    
    /* Test single (negative) byte */
    buffer[0] = 0x7e;
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), buffer, sizeof(buffer), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_sleb128(&mobj, buffer, 0, &result, &size);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode sleb128");
    STAssertEquals(result, (int64_t)-2, @"Incorrect value decoded");
    STAssertEquals(size, (pl_vm_size_t)1, @"Incorrect byte length");
    plcrash_async_mobject_free(&mobj);
    
    /* Test multi-byte */
    buffer[0] = 0+0x80;
    buffer[1] = 1;
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), buffer, sizeof(buffer), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_sleb128(&mobj, buffer, 0, &result, &size);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode sleb128");
    STAssertEquals(result, (int64_t)128, @"Incorrect value decoded");
    STAssertEquals(size, (pl_vm_size_t)2, @"Incorrect byte length");
    plcrash_async_mobject_free(&mobj);
    
    /* Test -INT64_MAX */
    memset(buffer, 0x80, sizeof(buffer));
    buffer[9] = 0x7f;
    
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), buffer, sizeof(buffer), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_sleb128(&mobj, buffer, 0, &result, &size);
    STAssertEquals(err, PLCRASH_ESUCCESS, @"Failed to decode sleb128");
    STAssertEquals(result, INT64_MIN, @"Incorrect value decoded");
    STAssertEquals(size, (pl_vm_size_t)10, @"Incorrect byte length");
    plcrash_async_mobject_free(&mobj);
    
    /* Test handling of an integer larger than 64 bits. */
    memset(buffer, 0x80, sizeof(buffer));
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), buffer, sizeof(buffer), true), @"Failed to initialize mobj mapping");
    
    err = plcrash_async_dwarf_read_sleb128(&mobj, buffer, 0, &result, &size);
    STAssertEquals(err, PLCRASH_ENOTSUP, @"SLEB128 should not be decodable");
    plcrash_async_mobject_free(&mobj);
    
    /* Test end-of-buffer handling */
    STAssertEquals(PLCRASH_ESUCCESS, plcrash_async_mobject_init(&mobj, mach_task_self(), buffer, 1, true), @"Failed to initialize mobj mapping");
    buffer[0] = 1+0x80;
    err = plcrash_async_dwarf_read_sleb128(&mobj, buffer, 0, &result, &size);
    STAssertEquals(err, PLCRASH_EINVAL, @"SLEB128 should not be decodable");
    plcrash_async_mobject_free(&mobj);
}

@end
