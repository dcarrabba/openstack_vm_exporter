# OpenStack VM Exporter

[![License](https://img.shields.io/badge/License-MIT-green.svg)]()
[![Shell Script](https://img.shields.io/badge/language-bash-blue.svg)]()
[![OpenStack](https://img.shields.io/badge/OpenStack-Compatible-red.svg)]()
[![Status](https://img.shields.io/badge/Build-Passing-brightgreen.svg)]()

A powerful, interactive Bash toolkit for exporting virtual machines from **any OpenStack environment**.  
Supports Cinder-based exports, Glance-based exports, multi-volume VMs, snapshots, auto-detection, auto-recovery, and optional conversion for **VMware** or **Hyper‑V**.

---

## 🚀 Features

- 📌 **Automatic Volume Detection**  
  Detects all volumes attached to a VM (boot + data).

- 📸 **Cinder Snapshot Export**  
  Creates snapshots and safe clone copies for export.

- 🖼️ **Glance Image Export (Fallback Method)**  
  If Cinder fails → automatic switch to Glance backend.

- 📥 **Direct Image Download**  
  Downloads QCOW2 images with progress indicator.

- 🔄 **Optional Conversion**  
  Convert QCOW2 → VHDX (Hyper-V) or VMDK (VMware).

- 🔧 **Automatic Dependency Installer**  
  Installs: `jq`, `qemu-utils`, `pv`, `glance`, `python-openstackclient`.

- 🛡️ **Supports Custom CA Certificates**  
  Works with private clouds and custom PKI.

- 📂 **Interactive Save Path Selection**  
  Choose where to save exported VM files.

---

## 📦 Requirements

```bash
Ubuntu 20.04+ or Debian-based system
Python OpenStack Client
Privileges to create snapshots & volumes
Cinder or Glance access
```

---

## 🔧 Installation

```bash
git clone https://github.com/dcarrabba/openstack_vm_exporter.git
cd openstack-vm-exporter
chmod +x openstack-vm-exporter.sh
```

---

## ▶️ How to Use

### 1️⃣ Load your OpenStack environment variables downloadable from openstack dashboard.

```bash
source open_environment.sh
```

### 2️⃣ Run the script

```bash
./openstack_export_vm.sh
```

You will be prompted for:
- VM name  
- Save path  
- Conversion options  

---

## 📘 Example Output

```bash
[+] Starting export of VM: myserver01
[*] Creating snapshot for volume: boot-disk
[✔] Snapshot created: snap-boot-disk
[*] Creating clone volume...
[✔] Clone ready: clone-boot-disk
[*] Creating Glance image...
[✔] Image active: img-boot-disk (42GB)
[*] Downloading image...
42GB  |████████████████████████████████████████████████████|  100%
[✔] Export complete!
```

---

## 🧩 Folder Structure

```bash
/root/imgstore/
 └── myserver01/
     ├── img-boot.qcow2
     ├── img-disk1.qcow2
     ├── img-disk2.qcow2
     └── logs/
         └── myserver01_2025-02-10.log
```

---

## 🖥️ Example Conversion

### Convert QCOW2 → Hyper‑V VHDX

```bash
qemu-img convert -f qcow2 -O vhdx input.qcow2 output.vhdx
```

### Convert QCOW2 → VMware VMDK

```bash
qemu-img convert -f qcow2 -O vmdk input.qcow2 output.vmdk
```

---

## 🛠️ Troubleshooting

### ❗ "VolumeSizeExceedsAvailableQuota"
Your OpenStack project has insufficient Cinder quota.  
Solution: increase quota or use Glance export method.

### ❗ "unable to verify the first certificate"
Your CA chain is missing.  
Fix by adding:

```bash
export OS_CACERT=/etc/ssl/certs/mychain.pem
```

---

## 🗺️ Roadmap / TODO

- [ ] Add automatic Glance→Cinder fallback handling  
- [ ] Add support for Swift-based binary export  
- [ ] Add parallel download for multi‑volume VMs  
- [ ] Add checksum + integrity verification  
- [ ] Add colorized output  

---

## 🤝 Contributing

Pull requests are welcome!  
Follow GitHub standard flow (fork → branch → PR).

---

## 📜 License

Released under the **MIT License**.

---

## 👤 Credits

Developed by **Davide Carrabba**  
Designed for high‑performance exports from complex OpenStack infrastructures.

