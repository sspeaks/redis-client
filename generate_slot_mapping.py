#!/usr/bin/env python3
"""
Script to generate a flat data file mapping cluster slots to short strings.
For each slot number (0-16383), this finds a 3-4 character string that hashes to that slot.
"""

import itertools
import string

# CRC16 implementation matching the C code in crc16.c
CRC16TAB = [
    0x0000, 0x1021, 0x2042, 0x3063, 0x4084, 0x50a5, 0x60c6, 0x70e7,
    0x8108, 0x9129, 0xa14a, 0xb16b, 0xc18c, 0xd1ad, 0xe1ce, 0xf1ef,
    0x1231, 0x0210, 0x3273, 0x2252, 0x52b5, 0x4294, 0x72f7, 0x62d6,
    0x9339, 0x8318, 0xb37b, 0xa35a, 0xd3bd, 0xc39c, 0xf3ff, 0xe3de,
    0x2462, 0x3443, 0x0420, 0x1401, 0x64e6, 0x74c7, 0x44a4, 0x5485,
    0xa56a, 0xb54b, 0x8528, 0x9509, 0xe5ee, 0xf5cf, 0xc5ac, 0xd58d,
    0x3653, 0x2672, 0x1611, 0x0630, 0x76d7, 0x66f6, 0x5695, 0x46b4,
    0xb75b, 0xa77a, 0x9719, 0x8738, 0xf7df, 0xe7fe, 0xd79d, 0xc7bc,
    0x48c4, 0x58e5, 0x6886, 0x78a7, 0x0840, 0x1861, 0x2802, 0x3823,
    0xc9cc, 0xd9ed, 0xe98e, 0xf9af, 0x8948, 0x9969, 0xa90a, 0xb92b,
    0x5af5, 0x4ad4, 0x7ab7, 0x6a96, 0x1a71, 0x0a50, 0x3a33, 0x2a12,
    0xdbfd, 0xcbdc, 0xfbbf, 0xeb9e, 0x9b79, 0x8b58, 0xbb3b, 0xab1a,
    0x6ca6, 0x7c87, 0x4ce4, 0x5cc5, 0x2c22, 0x3c03, 0x0c60, 0x1c41,
    0xedae, 0xfd8f, 0xcdec, 0xddcd, 0xad2a, 0xbd0b, 0x8d68, 0x9d49,
    0x7e97, 0x6eb6, 0x5ed5, 0x4ef4, 0x3e13, 0x2e32, 0x1e51, 0x0e70,
    0xff9f, 0xefbe, 0xdfdd, 0xcffc, 0xbf1b, 0xaf3a, 0x9f59, 0x8f78,
    0x9188, 0x81a9, 0xb1ca, 0xa1eb, 0xd10c, 0xc12d, 0xf14e, 0xe16f,
    0x1080, 0x00a1, 0x30c2, 0x20e3, 0x5004, 0x4025, 0x7046, 0x6067,
    0x83b9, 0x9398, 0xa3fb, 0xb3da, 0xc33d, 0xd31c, 0xe37f, 0xf35e,
    0x02b1, 0x1290, 0x22f3, 0x32d2, 0x4235, 0x5214, 0x6277, 0x7256,
    0xb5ea, 0xa5cb, 0x95a8, 0x8589, 0xf56e, 0xe54f, 0xd52c, 0xc50d,
    0x34e2, 0x24c3, 0x14a0, 0x0481, 0x7466, 0x6447, 0x5424, 0x4405,
    0xa7db, 0xb7fa, 0x8799, 0x97b8, 0xe75f, 0xf77e, 0xc71d, 0xd73c,
    0x26d3, 0x36f2, 0x0691, 0x16b0, 0x6657, 0x7676, 0x4615, 0x5634,
    0xd94c, 0xc96d, 0xf90e, 0xe92f, 0x99c8, 0x89e9, 0xb98a, 0xa9ab,
    0x5844, 0x4865, 0x7806, 0x6827, 0x18c0, 0x08e1, 0x3882, 0x28a3,
    0xcb7d, 0xdb5c, 0xeb3f, 0xfb1e, 0x8bf9, 0x9bd8, 0xabbb, 0xbb9a,
    0x4a75, 0x5a54, 0x6a37, 0x7a16, 0x0af1, 0x1ad0, 0x2ab3, 0x3a92,
    0xfd2e, 0xed0f, 0xdd6c, 0xcd4d, 0xbdaa, 0xad8b, 0x9de8, 0x8dc9,
    0x7c26, 0x6c07, 0x5c64, 0x4c45, 0x3ca2, 0x2c83, 0x1ce0, 0x0cc1,
    0xef1f, 0xff3e, 0xcf5d, 0xdf7c, 0xaf9b, 0xbfba, 0x8fd9, 0x9ff8,
    0x6e17, 0x7e36, 0x4e55, 0x5e74, 0x2e93, 0x3eb2, 0x0ed1, 0x1ef0
]

def crc16(data):
    """Calculate CRC16 for the given data."""
    if isinstance(data, str):
        data = data.encode('utf-8')
    
    crc = 0
    for byte in data:
        crc = ((crc << 8) ^ CRC16TAB[((crc >> 8) ^ byte) & 0x00FF]) & 0xFFFF
    return crc

def calculate_slot(key):
    """Calculate the Redis cluster slot for a given key (matching Haskell implementation)."""
    crc = crc16(key)
    return crc % (2 ** 14)  # mod 16384

def generate_slot_strings():
    """
    Generate a mapping of slot numbers to strings that hash to those slots.
    Uses 3-4 character alphanumeric strings.
    """
    print("Generating slot to string mapping...")
    
    # Initialize the mapping
    slot_to_string = {}
    
    # Characters to use: letters (both cases) and digits
    charset = string.ascii_letters + string.digits
    
    # Try to find a string for each slot
    found_count = 0
    
    # First try 3-character strings
    print("Trying 3-character strings...")
    for combo in itertools.product(charset, repeat=3):
        if found_count == 16384:
            break
        
        test_string = ''.join(combo)
        slot = calculate_slot(test_string)
        
        if slot not in slot_to_string:
            slot_to_string[slot] = test_string
            found_count += 1
            
            if found_count % 1000 == 0:
                print(f"  Found {found_count}/16384 slots...")
    
    # If we still have missing slots, try 4-character strings
    if found_count < 16384:
        print(f"Found {found_count} with 3 chars, trying 4-character strings for remaining slots...")
        for combo in itertools.product(charset, repeat=4):
            if found_count == 16384:
                break
            
            test_string = ''.join(combo)
            slot = calculate_slot(test_string)
            
            if slot not in slot_to_string:
                slot_to_string[slot] = test_string
                found_count += 1
                
                if found_count % 100 == 0:
                    print(f"  Found {found_count}/16384 slots...")
    
    print(f"Completed! Found strings for {found_count}/16384 slots")
    return slot_to_string

def save_mapping(slot_to_string, filename='cluster_slot_mapping.txt'):
    """Save the mapping to a file in a format easy to load in Haskell."""
    print(f"Saving mapping to {filename}...")
    
    with open(filename, 'w') as f:
        # Write each slot number and its corresponding string
        for slot in range(16384):
            if slot in slot_to_string:
                f.write(f"{slot} {slot_to_string[slot]}\n")
            else:
                print(f"WARNING: No string found for slot {slot}")
    
    print(f"Mapping saved to {filename}")

def verify_mapping(slot_to_string):
    """Verify that all mappings are correct."""
    print("\nVerifying mapping...")
    
    errors = []
    for slot, string in slot_to_string.items():
        calculated_slot = calculate_slot(string)
        if calculated_slot != slot:
            errors.append(f"ERROR: Slot {slot} -> '{string}' -> {calculated_slot}")
    
    if errors:
        print(f"Found {len(errors)} errors:")
        for error in errors[:10]:  # Show first 10 errors
            print(f"  {error}")
        return False
    else:
        print("✓ All mappings verified successfully!")
        print(f"  Total slots: {len(slot_to_string)}")
        
        # Show some examples
        print("\nSample mappings:")
        for i in [0, 1, 100, 1000, 8000, 16383]:
            if i in slot_to_string:
                print(f"  Slot {i:5d} -> '{slot_to_string[i]}'")
        
        return True

def main():
    """Main function to generate and verify the slot mapping."""
    print("=" * 60)
    print("Redis Cluster Slot Mapping Generator")
    print("=" * 60)
    print()
    
    # Generate the mapping
    slot_to_string = generate_slot_strings()
    
    # Verify the mapping
    if not verify_mapping(slot_to_string):
        print("\n❌ Verification failed! Not saving mapping.")
        return 1
    
    # Save the mapping
    save_mapping(slot_to_string)
    
    print("\n" + "=" * 60)
    print("Done!")
    print("=" * 60)
    return 0

if __name__ == "__main__":
    exit(main())
