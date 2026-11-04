#!/usr/bin/env bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# Export Proxmox QEMU VM specs to CSV
set -euo pipefail

# Ensure needed commands exist
for cmd in qm awk sed grep tr; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Error: '$cmd' not found"; exit 1; }
done

# Convert size string like "50G", "512M", "102400K" to GB (with 2 decimals)
to_gb() {
  local s="${1:-0}"
  s="$(echo -n "$s" | tr -d ' ')"
  if [[ "$s" =~ ^[0-9]+$ ]]; then
    awk -v bytes="$s" 'BEGIN{printf "%.2f", bytes/1024/1024/1024}'
    return
  fi
  if [[ "$s" =~ ^([0-9]+(\.[0-9]+)?)([KkMmGgTtBb])$ ]]; then
    local num unit
    num="$(echo "$s" | sed -E 's/^([0-9]+(\.[0-9]+)?)[A-Za-z]$/\1/')"
    unit="$(echo "$s" | sed -E 's/^([0-9]+(\.[0-9]+)?)([A-Za-z])$/\3/' | tr '[:lower:]' '[:upper:]')"
    case "$unit" in
      K) awk -v n="$num" 'BEGIN{printf "%.2f", n/1024/1024}' ;;
      M) awk -v n="$num" 'BEGIN{printf "%.2f", n/1024}' ;;
      G) awk -v n="$num" 'BEGIN{printf "%.2f", n}' ;;
      T) awk -v n="$num" 'BEGIN{printf "%.2f", n*1024}' ;;
      B) awk -v n="$num" 'BEGIN{printf "%.2f", n/1024/1024/1024}' ;;
      *) echo "0.00" ;;
    esac
  else
    echo "0.00"
  fi
}

# Sum of disk sizes (in GB) from qm config lines
sum_disks_gb() {
  local cfg="$1"
  echo "$cfg" | awk '
    /^[[:alnum:]]+(virtio|scsi|sata|ide)?[0-9]*:/ || /^[[:alpha:]]+[0-9]+:/ {
      n = split($0, arr, ",")
      for (i=1; i<=n; i++) {
        if (arr[i] ~ /size=/) {
          sub(/^.*size=/, "", arr[i])
          print arr[i]
        }
      }
    }' | while read -r sz; do
      to_gb "$sz"
    done | awk '{sum+=$1} END{printf "%.2f", (sum==0?0:sum)}'
}

# CSV Header (Menambahkan Status dan MAC_Address)
echo "VMID,Name,Status,vCPU,RAM(MB),TotalDisk(GB),MAC_Address"

# Iterate QEMU VMs
while read -r vmid status; do
  cfg="$(qm config "$vmid" 2>/dev/null || true)"
  [[ -z "$cfg" ]] && continue

  name="$(echo "$cfg" | awk -F': ' '/^name:/{print $2}' )"
  cores="$(echo "$cfg"   | awk -F': ' '/^cores:/{print $2}')"
  sockets="$(echo "$cfg" | awk -F': ' '/^sockets:/{print $2}')"
  vcpus_param="$(echo "$cfg"| awk -F': ' '/^vcpus:/{print $2}')"

  # Defaults
  [[ -z "${cores}" ]] && cores=0
  [[ -z "${sockets}" ]] && sockets=1

  # Compute vCPU
  if [[ -n "$vcpus_param" ]]; then
    vcpu="$vcpus_param"
  else
    if [[ "$cores" -gt 0 ]]; then
      vcpu=$(( cores * sockets ))
    else
      vcpu=0
    fi
  fi

  # RAM in MB
  ram_mb="$(echo "$cfg" | awk -F': ' '/^memory:/{print $2}')"
  [[ -z "$ram_mb" ]] && ram_mb=0

  # Sum disks
  total_gb="$(sum_disks_gb "$cfg")"

  # Ambil MAC Address dari interface net0, net1, dst.
  mac_address="$(echo "$cfg" | grep -E "^net[0-9]:" | grep -oE "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}" | tr '\n' ';' | sed 's/;$//')"
  [[ -z "$mac_address" ]] && mac_address="No-NIC"

  # Escape name jika ada koma atau tanda kutip
  if [[ "$name" =~ [\",] ]]; then
    name_escaped="\"$(echo "$name" | sed 's/\"/\"\"/g')\""
  else
    name_escaped="$name"
  fi

  echo "${vmid},${name_escaped:-No-Name},${status},${vcpu},${ram_mb},${total_gb},${mac_address}"
done < <(qm list | awk 'NR>1 {print $1, $3}')