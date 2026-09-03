# Build Notes

Step-by-step record in the order it actually happened. Environment: Windows
Server 2022 as a VM on Proxmox VE, in a dual-site lab with flat OSPF area 0
across a route-based IPsec tunnel between a Palo Alto PA-440 (WEST) and a
Juniper SRX345 (EAST).

**Design constraint driving the whole sequence: build in layers you can verify
independently.** Each phase ends with a check. If AD DS, DNS, and DHCP all land
in one operation and something is wrong, you are bisecting three subsystems at
once with no known-good checkpoint between them.

| | |
|---|---|
| Hostname | `CA-DC-01` |
| Domain | `casey.corp` (NetBIOS `CASEY`) |
| IP | `10.20.2.5/24`, gateway `10.20.2.1` — VLAN 20, WEST |
| VM | 2 vCPU, 4 GB, 80 GB thin, VirtIO SCSI |
| OS | Windows Server 2022 Standard, Desktop Experience |

*On sizing: an earlier attempt at this build ran Server 2025 on a host whose SSD
had a failing write path, and needed 4 vCPU / 8 GB to be usable. Once the
storage was replaced and the OS changed to 2022, 2 vCPU / 4 GB proved sufficient.
The larger figure in
[that write-up](https://github.com/117caseyallen-NetAdm/casey-lab/blob/main/docs/diagnosing-a-failing-ssd.md)
was compensating for hardware, not a requirement of the role.*

## 1. VM creation

Windows-specific choices that matter on Proxmox:

- **VirtIO SCSI single** controller with `iothread` — Windows has no built-in
  VirtIO storage driver, so the installer shows **no disks** until you load it
  manually. Attach `virtio-win.iso` as a second CD **before first boot**.
- **q35 + OVMF (UEFI)** with an EFI disk and pre-enrolled Secure Boot keys.
- **Ballooning disabled.** Memory pressure on a DC produces ambiguous auth
  failures rather than obvious slowness.
- Proxmox **pins the machine type** for Windows guests (`pc-q35-11.0`). QEMU's
  chipset evolves between releases; freezing it means the guest never sees
  virtual hardware change out from under it and demand driver reinstalls or
  reactivation.

## 2. Install

Load the storage driver at the disk-selection screen — `vioscsi\2k22\amd64` for
Server 2022. Choose **Desktop Experience**, not Core: this is a learning build,
and stacking a GUI-less admin experience on top of learning AD is two learning
curves at once.

Post-install:

```powershell
# from the virtio CD: virtio-win-gt-x64.msi, then guest-agent\qemu-ga-x86_64.msi

Stop-Service WSearch
Set-Service WSearch -StartupType Disabled
```

Search indexing is useless on a domain controller and is a persistent source of
disk churn.

## 3. Rename FIRST — before the IP, before anything

```powershell
Rename-Computer -NewName "CA-DC-01" -Restart
```

```powershell
hostname
```

**This step nearly got skipped, and it would have been permanent.** A domain
controller's hostname becomes its AD object, its SPNs, its DNS SRV records, and
the SYSVOL/NETLOGON paths every client references. Renaming *after* promotion
means `netdom computername` with a careful multi-step dance, or demote → rename →
re-promote.

The near-miss is in [troubleshooting.md](troubleshooting.md).

## 4. Static IP

`10.20.2.5/24`, gateway `10.20.2.1`, **preferred DNS `10.20.2.5`** — itself.

That last part looks wrong and isn't. It will not resolve anything until
promotion installs the DNS role, which is expected. It also means the machine
cannot resolve internet names during setup — also expected, and not worth
chasing. Creating a new forest requires no external DNS.

## 5. Three-layer connectivity test

The same test used to validate the WireGuard build, because it proves the same
three layers:

```
ping 10.20.2.1      # VLAN 20 tagging + local SVI
ping 1.1.1.1        # firewall source-NAT for the data subnet + default route
ping 10.99.10.14    # far-site device — crosses OSPF and the IPsec tunnel
```

All three must pass before going further. **Promoting a domain controller onto a
broken underlay is exactly as miserable as debugging a VPN on one.**

Snapshot here as `pre-dcpromo` — sixty seconds now against a reinstall later.

## 6. Install AD DS — via PowerShell, not the GUI

```powershell
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
```

**Do not use the Add Roles and Features wizard for this.** It bundles everything
you tick into a single operation and reports one aggregate result — so an
unrelated component failing takes the whole batch down and hides which one broke.
That cost several attempts here; see [troubleshooting.md](troubleshooting.md).

`Install-WindowsFeature` with a single `-Name` installs exactly one thing and
returns a real error if it fails.

## 7. Promotion

```powershell
Install-ADDSForest -DomainName "casey.corp" -DomainNetbiosName "CASEY" `
  -ForestMode "WinThreshold" -DomainMode "WinThreshold" `
  -InstallDns:$true -CreateDnsDelegation:$false `
  -DatabasePath "C:\Windows\NTDS" -LogPath "C:\Windows\NTDS" `
  -SysvolPath "C:\Windows\SYSVOL" -Force:$true
```

- **`WinThreshold`** is the string for the Server 2016 functional level. What
  matters is being able to explain what a functional level *controls*: the
  minimum DC OS version permitted in the forest, which gates which AD features
  are available forest-wide.
- **`-InstallDns:$true`** — this is why DNS was not pre-installed. Promotion
  creates `casey.corp` as an **AD-integrated** zone, replicated with the
  directory itself.
- **`-CreateDnsDelegation:$false`** — there is no parent zone to delegate from.
  The warning about this during promotion is expected.
- The **DSRM password** is prompted interactively rather than passed as a
  parameter, keeping it out of shell history. It is the break-glass credential
  for Directory Services Restore Mode.

Reboots itself. Log back in as `CASEY\Administrator`.

## 8. Verify — and read `dcdiag` properly

```
dcdiag
net share
```

`SYSVOL` and `NETLOGON` must appear in `net share`.

**Two `dcdiag` tests fail on every healthy freshly-promoted single DC.** Reading
them correctly is covered in [troubleshooting.md](troubleshooting.md) — it is
the single most useful thing in this document.

## 9. DNS

```powershell
Set-DnsServerForwarder -IPAddress 1.1.1.1, 9.9.9.9
Resolve-DnsName casey.corp     # local zone, authoritative
Resolve-DnsName google.com     # via forwarder
```

Reverse lookup zones for every subnet — the step most homelabs skip:

```powershell
Add-DnsServerPrimaryZone -NetworkID "10.20.2.0/24"  -ReplicationScope Domain
Add-DnsServerPrimaryZone -NetworkID "10.10.1.0/24"  -ReplicationScope Domain
Add-DnsServerPrimaryZone -NetworkID "10.99.20.0/24" -ReplicationScope Domain
Add-DnsServerPrimaryZone -NetworkID "10.99.10.0/24" -ReplicationScope Domain
Add-DnsServerPrimaryZone -NetworkID "10.99.0.0/24"  -ReplicationScope Domain
```

That last zone covers the firewall management loopbacks, which live in neither
site's management /24.

Then A records for static infrastructure, with `-CreatePtr` to populate reverse
records in the same command. Full list:
[`configs/dns-records.ps1`](../configs/dns-records.ps1).

```powershell
Resolve-DnsName prox-lab.casey.corp    # forward
Resolve-DnsName 10.99.10.14            # reverse → arista710p-lab.casey.corp
```

**Reverse DNS is what turns firewall and SIEM logs from IP soup into readable
names.** It costs five commands.

## 10. Time

Full config: [`configs/time-configuration.ps1`](../configs/time-configuration.ps1).

```powershell
w32tm /config /manualpeerlist:"time.cloudflare.com,0x8" /syncfromflags:manual /reliable:yes /update
Restart-Service w32time
w32tm /resync /rediscover
w32tm /query /status
```

**`/resync /rediscover` is required** — configuring a peer does not force an
immediate poll, and without it the status keeps reporting `Local CMOS Clock`.

Look for `Source:` naming the external peer and `ReferenceId` showing its
address, not `0x4C4F434C` (`"LOCL"`).

**Only the PDC emulator needs this.** Every domain member inherits time through
the domain hierarchy automatically — which is exactly why W32Time logs a warning
on promotion: the PDC emulator is the top of that hierarchy with nothing above
it. Confirmed later by `nltest /sc_query` on a member reporting `HAS_TIMESERV`.

*Improvement noted for later: a single NTP source is an undetectable single point
of failure. NTP's algorithm exists to compare several servers and identify a
falseticker — with one peer there is nothing to compare against. Three or four
peers is standard practice.*

## 11. DHCP

```powershell
Install-WindowsFeature -Name DHCP -IncludeManagementTools
Add-DhcpServerInDC -DnsName ca-dc-01.casey.corp -IPAddress 10.20.2.5
Get-DhcpServerInDC
```

**Authorization is an AD safety feature** — a Windows DHCP server refuses to
lease addresses on a domain network until registered in AD. It is how the
directory prevents a rogue DHCP server from poisoning clients.

Scopes for both sites, and the relay on the EAST distribution switch:
[`configs/dhcp-scopes.ps1`](../configs/dhcp-scopes.ps1) ·
[`configs/3560cg-1-dhcp-relay.txt`](../configs/3560cg-1-dhcp-relay.txt)

**VLAN 20 (WEST) needs no helper** — the server is on that subnet, so client
broadcasts reach it directly. **VLAN 10 (EAST) needs one**, because broadcasts do
not cross routers.

Verified by releasing/renewing a client at EAST and confirming the lease on the
server:

```powershell
Get-DhcpServerv4Lease -ScopeId 10.10.1.0
```

## 12. Reservations over statics

```powershell
Add-DhcpServerv4Reservation -ScopeId 10.10.1.0 -IPAddress 10.10.1.10 `
  -ClientId "<CLIENT_MAC>" -Name "CA-WIN-LAB" -Description "EAST jumpbox"
```

A reservation gives a device a predictable address while keeping the assignment
**in one place you can query and audit**, instead of typed into a machine you
have to log into to discover. Centralised address management is the entire point
of running DHCP; hardcoding statics on endpoints undermines it.

Infrastructure that must work *when DHCP is down* — switches, firewalls, the DC
itself — stays genuinely static.

*Note: a reservation does not move a client already holding a lease. Delete the
old lease and release/renew.*

## 13. Domain join — the cross-site test

On a client at **EAST**:

```powershell
nltest /dsgetdc:casey.corp    # run this FIRST
```

That performs the same DC-locator process the join will use — query DNS for
`_ldap._tcp.dc._msdcs.casey.corp`, get a DC, verify it answers. If it fails, fix
DNS rather than watching the join fail more cryptically.

```powershell
Add-Computer -DomainName casey.corp -Credential (Get-Credential CASEY\Administrator) -Restart
```

Verify:

```powershell
Get-ComputerInfo | Select-Object CsDomain, CsDomainRole
nltest /sc_query:casey.corp
```

```
Flags: 30 HAS_IP  HAS_TIMESERV  Authentication Service: Netlogon
Trusted DC Name \\CA-DC-01.casey.corp
Trusted DC Connection Status Status = 0 0x0 NERR_Success
```

`NERR_Success` confirms a working **Netlogon secure channel** from an EAST client
to a WEST domain controller — located via SRV records, across the IPsec tunnel.
Note the output names the service itself: `Authentication Service: Netlogon`.
This validates the channel, not Kerberos specifically; `klist` after a domain
logon is what shows actual Kerberos tickets.

`HAS_TIMESERV` confirms the DC is serving time to this client, so the hierarchy
in §10 is working with no client-side configuration.

## 14. GPO baseline

Inbound ICMP first, so ping stops needing per-machine configuration:

`Computer Configuration → Policies → Windows Settings → Security Settings →
Windows Defender Firewall with Advanced Security → Inbound Rules` →
New Rule → Predefined → **File and Printer Sharing** → *Echo Request - ICMPv4-In*
→ Allow.

Create a **new GPO** rather than editing Default Domain Policy — keeping the
defaults untouched makes later troubleshooting far easier.

```
gpupdate /force
```

## Future work

- **Second domain controller.** On a single host this is not true redundancy —
  and saying so plainly matters more than the build. What it provides is real
  multi-master replication to observe and repair, FSMO transfer/seizure practice,
  and DNS redundancy so one DC rebooting doesn't black-hole name resolution.
  It becomes genuine redundancy the moment a second physical node exists.
- **Multiple NTP peers** (see §10)
- **LDAP hardening** — the promotion event log recommends rejecting SASL binds
  without signing, and enforcing Channel Binding Token validation on LDAPS.
  Both are real hardening, surfaced by the system itself.
- **802.1X** via NPS, and internal PKI
- **Split-DNS** for VPN clients
