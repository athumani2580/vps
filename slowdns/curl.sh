#!/bin/bash

# Fix for curl permission error during reinstall

echo "=== Fixing curl permission error ==="

# 1. Check filesystem status
echo "1. Checking filesystem..."
mount | grep " / "
echo ""

# 2. Remount as read-write if needed
echo "2. Remounting filesystem as read-write..."
mount -o remount,rw / 2>/dev/null
mount -o remount,rw /boot 2>/dev/null
echo ""

# 3. Check disk space
echo "3. Checking disk space..."
df -h /
echo ""

# 4. Create backup of old file if exists
echo "4. Cleaning up old files..."
if [ -f /reinstall-vmlinuz ]; then
    mv /reinstall-vmlinuz /reinstall-vmlinuz.backup
    echo "Backup created: /reinstall-vmlinuz.backup"
fi
echo ""

# 5. Create file with correct permissions
echo "5. Creating file with proper permissions..."
touch /reinstall-vmlinuz
chmod 644 /reinstall-vmlinuz
echo ""

# 6. Try curl with verbose output
echo "6. Testing curl download..."
echo "Attempting to download from: $nextos_vmlinuz"
curl -v -Lo /reinstall-vmlinuz "$nextos_vmlinuz"

if [ $? -eq 0 ]; then
    echo "✅ Download successful!"
    ls -lh /reinstall-vmlinuz
else
    echo "❌ Curl failed, trying wget..."
    
    # 7. Try wget as alternative
    if command -v wget >/dev/null 2>&1; then
        wget -O /reinstall-vmlinuz "$nextos_vmlinuz"
        if [ $? -eq 0 ]; then
            echo "✅ Wget download successful!"
        else
            echo "❌ Both curl and wget failed"
            echo "Trying alternative download method..."
            
            # 8. Use Python as last resort
            python3 -c "
import urllib.request
import sys
try:
    urllib.request.urlretrieve('$nextos_vmlinuz', '/reinstall-vmlinuz')
    print('✅ Python download successful')
except Exception as e:
    print(f'❌ Python download failed: {e}')
    sys.exit(1)
            "
        fi
    else
        echo "⚠️  wget not available, installing..."
        apt-get update && apt-get install -y wget
        wget -O /reinstall-vmlinuz "$nextos_vmlinuz"
    fi
fi

echo ""
echo "=== Fix completed ==="
