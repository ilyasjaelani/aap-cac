#!/usr/bin/env bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# Hilangkan opsi 'e' agar script tidak langsung mati jika cluster throwing error
set -uo pipefail

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

echo "VMID,Name,vCPU,RAM(MB),TotalDisk(GB)"

# Ambil list VMID, saring pesan error ipcc/corosync
vm_ids=$(qm list 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}')

if [[ -z "$vm_ids" ]]; then
  # Fallback jika qm list gagal total karena quorum: baca langsung dari folder lokal node
  hn=$(hostname)
  if [[ -d "/etc/pve/nodes/$hn/qemu-server" ]]; then
    vm_ids=$(ls /etc/pve/nodes/"$hn"/qemu-server/*.conf 2>/dev/null | grep -oE '[0-9]+' || true)
  fi
fi

for vmid in $vm_ids; do
  # Ambil config dari qm, jika gagal/error ambil dari file .conf langsung
  cfg=$(qm config "$vmid" 2>/dev/null || true)
  if [[ -z "$cfg" ]]; then
    hn=$(hostname)
    conf_file="/etc/pve/nodes/$hn/qemu-server/${vmid}.conf"
    [[ -f "$conf_file" ]] && cfg=$(cat "$conf_file" 2>/dev/null || true)
  fi

  [[ -z "$cfg" ]] && continue

  name="$(echo "$cfg" | awk -F': ' '/^name:/{print $2}')"
  cores="$(echo "$cfg" | awk -F': ' '/^cores:/{print $2}')"
  sockets="$(echo "$cfg" | awk -F': ' '/^sockets:/{print $2}')"
  vcpus_param="$(echo "$cfg" | awk -F': ' '/^vcpus:/{print $2}')"

  [[ -z "${cores}" ]] && cores=0
  [[ -z "${sockets}" ]] && sockets=1

  if [[ -n "$vcpus_param" ]]; then
    vcpu="$vcpus_param"
  else
    if [[ "$cores" -gt 0 ]]; then
      vcpu=$(( cores * sockets ))
    else
      vcpu=0
    fi
  fi

  ram_mb="$(echo "$cfg" | awk -F': ' '/^memory:/{print $2}')"
  [[ -z "$ram_mb" ]] && ram_mb=0

  total_gb="$(sum_disks_gb "$cfg")"

  if [[ "$name" =~ [\",] ]]; then
    name_escaped="\"$(echo "$name" | sed 's/\"/\"\"/g')\""
  else
    name_escaped="$name"
  fi

  echo "${vmid},${name_escaped:-No-Name},${vcpu},${ram_mb},${total_gb}"
done