#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# CSV Header
echo "VMID,Name,vCPU,RAM(MB),TotalDisk(GB)"

# Ambil list VMID
vm_ids=$(qm list 2>/dev/null | awk 'NR>1 {print $1}')

for vmid in $vm_ids; do
  cfg=$(qm config "$vmid" 2>/dev/null)
  [ -z "$cfg" ] && continue

  name=$(echo "$cfg" | awk -F': ' '/^name:/{print $2}')
  cores=$(echo "$cfg" | awk -F': ' '/^cores:/{print $2}')
  sockets=$(echo "$cfg" | awk -F': ' '/^sockets:/{print $2}')
  vcpus=$(echo "$cfg" | awk -F': ' '/^vcpus:/{print $2}')

  [ -z "$cores" ] && cores=1
  [ -z "$sockets" ] && sockets=1

  if [ -n "$vcpus" ]; then
    vcpu="$vcpus"
  else
    vcpu=$((cores * sockets))
  fi

  ram_mb=$(echo "$cfg" | awk -F': ' '/^memory:/{print $2}')
  [ -z "$ram_mb" ] && ram_mb=0

  # Hitung Total Disk dalam GB
  total_gb=$(echo "$cfg" | awk '/(scsi|sata|virtio|ide)[0-9]*:/ {
    n = split($0, arr, ",")
    for (i=1; i<=n; i++) {
      if (arr[i] ~ /size=/) {
        sub(/^.*size=/, "", arr[i])
        sz = arr[i]
        unit = substr(sz, length(sz))
        val = substr(sz, 1, length(sz)-1)
        if (unit == "G" || unit == "g") sum += val
        else if (unit == "M" || unit == "m") sum += val/1024
        else if (unit == "T" || unit == "t") sum += val*1024
        else sum += val
      }
    }
  } END {printf "%.2f", sum}')

  [ -z "$total_gb" ] && total_gb="0.00"

  echo "${vmid},${name:-No-Name},${vcpu},${ram_mb},${total_gb}"
done