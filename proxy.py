#!/usr/bin/env python3
import socket
import struct
import sys

# === CONFIGURATION ===
LISTEN_ADDR = '0.0.0.0'
LISTEN_PORT = 53        # Port the client connects to
SERVER_ADDR = '127.0.0.1'
SERVER_PORT = 5300      # Your SlowDNS server port
MAX_CLIENT_MTU = 512    # Firewall limit
MAX_SERVER_MTU = 1800   # Server capacity

def modify_edns(data, new_size):
    """
    Locates the OPT RR (EDNS0) in a DNS packet and updates the UDP payload size.
    DNS OPT RR Type is 41 (0x0029).
    """
    try:
        packet = bytearray(data)
        # DNS Header is 12 bytes. We start searching after that.
        # We look for the 00 29 (Type 41) which marks the OPT record.
        for i in range(12, len(packet) - 4):
            if packet[i] == 0x00 and packet[i+1] == 0x29:
                # The 2 bytes immediately following Type 41 are the Payload Size
                size_bytes = struct.pack("!H", new_size)
                packet[i+2:i+4] = size_bytes
                return bytes(packet)
        return data
    except Exception:
        return data

def main():
    # Create UDP socket
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind((LISTEN_ADDR, LISTEN_PORT))
    except PermissionError:
        print("[!] Error: You must run this script as root to bind to port 53.")
        sys.exit(1)

    print(f"[*] SlowDNS Proxy Active")
    print(f"[*] Listening: {LISTEN_ADDR}:{LISTEN_PORT} (Clamping to {MAX_CLIENT_MTU})")
    print(f"[*] Forwarding: {SERVER_ADDR}:{SERVER_PORT} (Expanding to {MAX_SERVER_MTU})")

    # Dictionary to keep track of client addresses
    client_map = {}

    while True:
        try:
            data, addr = sock.recvfrom(4096)

            if addr[0] == SERVER_ADDR and addr[1] == SERVER_PORT:
                # --- DOWNSTREAM: SERVER -> PROXY -> CLIENT ---
                # 1. Identify which client this response is for (based on DNS ID)
                dns_id = data[:2]
                if dns_id in client_map:
                    target_client = client_map[dns_id]
                    
                    # 2. Modify EDNS back to 512 for the client/firewall
                    modified_data = modify_edns(data, MAX_CLIENT_MTU)
                    
                    # 3. CRITICAL: Physical Truncation
                    # If the server sent > 512, we must slice it or the firewall drops it.
                    if len(modified_data) > MAX_CLIENT_MTU:
                        # Set Truncated bit (TC) in header so client knows it was cut
                        header = bytearray(modified_data[:12])
                        header[2] |= 0x02 
                        final_packet = bytes(header) + modified_data[12:MAX_CLIENT_MTU]
                    else:
                        final_packet = modified_data

                    sock.sendto(final_packet, target_client)
            
            else:
                # --- UPSTREAM: CLIENT -> PROXY -> SERVER ---
                # 1. Store client address by DNS ID to route the response later
                dns_id = data[:2]
                client_map[dns_id] = addr
                
                # 2. Modify EDNS to 1800 so the server sends larger chunks
                modified_data = modify_edns(data, MAX_SERVER_MTU)
                
                # 3. Forward to the actual SlowDNS server
                sock.sendto(modified_data, (SERVER_ADDR, SERVER_PORT))

        except KeyboardInterrupt:
            print("\n[*] Shutting down proxy.")
            break
        except Exception as e:
            print(f"[!] Runtime error: {e}")

if __name__ == "__main__":
    main()
