OpenStack VM Export Tool

A universal, interactive VM export tool for OpenStack (Glance & Cinder compatible)



🚀 Overview

OpenStack VM Export Tool is a robust Bash script designed to export virtual machines from any OpenStack environment—with maximum compatibility.

It supports both Glance and Cinder backends and can automatically:

Create snapshots

Create clone volumes

Generate Glance images

Download disk images

Convert them for Hyper-V or VMware

Install missing dependencies

Handle OpenStack variations transparently

This script is ideal for migration, disaster recovery, inter-cloud export, and offline backup.

⭐ Features
✔ Fully interactive

The script asks for:

VM name

Export path

Whether you want to convert images

Target hypervisor format (Hyper-V / VMware)

✔ Maximum OpenStack compatibility

Supports both methods automatically:

Method	Used when
openstack image create --volume	Primary image export path
cinder upload-to-image	Fallback for clouds that do not support the above
✔ Automatic dependency installation

The script detects and installs required tools:

jq

pv

qemu-img

python3-openstackclient

python3-cinderclient

Works with:
apt, yum, dnf.

✔ Safe & idempotent

Reuses existing snapshots

Reuses existing cloned volumes

Reuses partial images

Can be resumed safely

✔ Optional disk conversion

Supports:

Hypervisor	Format
Hyper-V	VHDX
VMware	VMDK

(Uses qemu-img)

✔ Complete logging

All operations are logged to:

<export_path>/<VM_NAME>/logs/<VM>_<timestamp>.log

🛠 Requirements

Linux (Ubuntu, Debian, RHEL, Rocky, AlmaLinux)

Valid OS_* environment variables (from OpenStack RC file)

Proper SSL certificates (via OS_CACERT, if needed)

Volume management permissions in your project

📦 Installation

Clone the repo and make the script executable:

git clone https://github.com/<your-user>/<your-repo>.git
cd <your-repo>
chmod +x export_spc_vm.sh

▶️ Usage

Just run:

./export_spc_vm.sh


Example interactive session:

=============================================
 Export VM from OpenStack
=============================================

Enter the VM name: myserver01
Enter export directory (default: /root/imgstore): /exports

Convert downloaded QCOW2 images? [y/N]: y

Choose output format:
  1) Hyper-V (VHDX)
  2) VMware (VMDK)
Selection [1-2]: 1

[+] Creating snapshot...
[+] Creating clone volume...
[+] Creating image on Glance...
[+] Falling back to Cinder (if required)...
[+] Downloading image...
[+] Converting to VHDX...

📁 Output Structure
/exports/myserver01/
│
├── img-disk1.qcow2
├── img-disk1.vhdx (optional)
├── img-disk2.qcow2
├── img-disk2.vmdk (optional)
│
└── logs/
    └── myserver01_20250101-153000.log

🧪 Tested On
✔ Operating Systems

Ubuntu 20.04 / 22.04 / 24.04

Rocky Linux 8 / 9

AlmaLinux 8

RHEL 8+

✔ OpenStack versions

Train

Ussuri

Victoria

Wallaby

Provider-custom variants

Clouds without Glance volume injection

🔐 Security Notes

Passwords are not saved.

Authentication depends solely on OS_* variables.

If using federated identity, ensure token validity.

📌 Roadmap

Planned improvements:

Parallel download acceleration

Resume broken downloads

Direct export to S3 / MinIO

Automatic compression (.xz or .gz)

Export VM metadata (flavor, networks, SGs)

🤝 Contributing

Contributions are welcome!
Feel free to open:

Issues

Pull requests

Feature proposals

📜 License

Released under the MIT License.
You are free to use, modify, and distribute for commercial or private use.

❤️ Credits

Script designed with a focus on:

Real-world OpenStack cloud variations

Reliability

Maximum portability

Migration use-cases (KVM → Hyper-V / VMware)
