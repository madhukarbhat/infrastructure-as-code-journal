# Infrastructure as Code Journal

A centralized knowledge base documenting enterprise-grade infrastructure automation, focusing on declarative provisioning and FreeBSD virtualization.

## 🎯 Purpose & Goals
* **Upskilling & Mastery:** Deep-diving into automated infrastructure patterns, state management, and lightweight virtualization.
* **Internal Runbook:** Serving as a reliable, repeatable reference vault for advanced systems engineering tasks.
* **Showcase:** Demonstrating a structured approach to Infrastructure as Code (IaC) and system orchestration for production-ready environments.

---

## 🛠️ Technology Stack & Focus Areas

### ⚙️ Automation & Orchestration
* **Terraform:** Declarative infrastructure provisioning, state management, and lifecycle handling.
* **Ansible:** Configuration management, idempotent playbooks, and bare-metal/VM bootstrapping.

### 🛡️ FreeBSD Virtualization & Isolation
* **Bhyve VM:** Hypervisor management, storage provisioning, and running heterogeneous guest OS instances.
* **Jails:** Container-like process isolation, network stack virtualization (VNET), and resource capping.

---

## 📂 Repository Structure

```text
├── terraform/          # Provisioning blueprints and infrastructure state definitions
├── ansible/            # Playbooks, inventory layout, and system configuration roles
├── bhyve/              # Hypervisor automation, guest provisions, and storage scripts
└── jails/              # Jail templates, VNET networking configurations, and ezjail/iocage setups
```

---

## 📖 Quick Reference Logs (Sample Structure)

### 📌 Terraform Tips
* Always verify state locks before forcing a plan.
* Command to format configuration: `terraform fmt -recursive`

### 📌 Ansible Gotchas
* Ensure `become: true` is scoped correctly to avoid privilege escalation failures on custom FreeBSD paths.

### 📌 Bhyve Quickstart
* Basic command template to spin up a guest VM:
  ```bash
  bhyve -c 2 -m 2G -H -P -A \
    -s 0,hostbridge \
    -s 3,ahci-hd,/dev/zvol/zroot/vms/guest_disk \
    -s 4,virtio-net,tap0 \
    -s 31,lpc -l bootrom,/usr/local/share/uefi-firmware/BHYVE_UEFI.fd \
    guest_vm_name
  ```

### 📌 Jail VNET Configuration
* Ensure the host bridge is up before assigning virtual interfaces to a jail.

---

## 🚀 Future Roadmap / To-Do
- [ ] Automate jail creation utilizing Ansible's community modules.
- [ ] Implement a local Terraform provider for headless Bhyve orchestration.
- [ ] Set up a CI/CD linting workflow using GitHub Actions for Terraform and Ansible configurations.
