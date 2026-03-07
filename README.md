<img src="https://github.com/user-attachments/assets/5057ec78-74b1-4455-b7d2-5d4046d70f62" width="100%">

# forensic

A bash tool that scans your drives for corruption, bad sectors, and malware — all in one shot.

---

## what it does

- detects all connected block devices
- checks S.M.A.R.T. health (drive is dying?)
- runs filesystem integrity checks (`fsck`, `ntfsfix`, `xfs_repair`, etc.)
- scans for bad sectors with `badblocks`
- runs a malware scan with ClamAV
- saves a full report to `~forensic/forensic_reports/`

auto-installs any missing tools it needs (`apt`, `dnf`, `pacman` supported).

---

## usage

```bash
# clone
git clone https://github.com/Hrishavvv/forensic.git
cd forensic

# make executable
chmod +x dskchk.sh

# run (sudo recommended for full access)
sudo ./dskchk.sh
```

pick a drive from the list, answer the prompts — done.

---

## requirements

- Linux (any major distro)
- `bash` 4+
- internet access on first run (to auto-install deps)
