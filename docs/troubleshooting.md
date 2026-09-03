# Troubleshooting Log

Every real problem hit during the build, what it looked like, and what it
actually was. Kept because the symptoms are generic and several of the causes
were not obvious.

## Reading `dcdiag` — two tests fail on every healthy DC

This is the most useful thing in this document. A freshly promoted single domain
controller **fails two `dcdiag` tests**, and neither indicates a problem.

### `SystemLog` — a log scraper, not a health check

`SystemLog` does exactly one thing: greps the System event log for errors in the
last 24 hours and fails if it finds any. Promotion itself generates transient
errors while services come up in a half-configured state, so this test fails on
essentially every new DC.

Actual entries seen, all clustered in the promotion window:

| Event | What it really was |
|---|---|
| `_ldap._tcp.dc._msdcs.casey.corp` resolution timed out | The DC querying its own SRV records **before DNS finished starting**. Chicken-and-egg during promotion |
| WinRM failed to create SPNs `WSMAN/CA-DC-01...` | SPN registration during the workgroup → domain transition |
| "account-identifier allocator was unable to assign a new identifier" | RID pool initialising on first promotion |
| "driver disabled the write cache on `\Device\Harddisk0\DR0`" | The VirtIO disk reporting its cache semantics |
| RD Session Host cannot register `TERMSRV` SPN | The Remote Desktop Session Host role isn't installed |
| `wpad` timed out | Web Proxy Auto-Discovery. Irrelevant |

**The technique that settles it: cross-reference live tests against log
entries.** The RID pool errors are contradicted by the `RidManager` test
**passing** — if the pool were genuinely broken, that test would fail. **The test
is current; the log is history.** A live check beats a log entry every time.

### `DFSREvent` — no replication partner

SYSVOL replicates via DFSR, and a single DC has nobody to replicate with, so DFSR
logs complaints. The check that actually matters is whether SYSVOL got shared:

```
net share          # SYSVOL and NETLOGON must be present
```

Combined with `SysVolCheck` passing, that's sufficient.

### One genuinely useful finding buried in the noise

The `KccEvent` output — which **passed** — contained real hardening
recommendations from the directory itself:

> *"...configuring the server to reject SASL LDAP binds that do not request
> signing, and simple binds performed on a clear-text connection..."*
> *"...enforce validation of Channel Binding Tokens received in LDAP bind
> requests sent over LDAPS..."*

LDAP signing and channel binding are legitimate hardening Microsoft has pushed
enterprises toward for years. **Worth reading passing tests, not just failing
ones.**

### Also seen: NLS sort version warnings

```
Out of date NLS sort version detected on the database 'ntds.dit'
The secondary index 'INDEX_00000003' of table 'datatable' is out of date...
Active Directory Domain Services has detected and deleted some possibly
corrupted indices as part of initialization.
```

The AD database was built with one Unicode sorting library and Windows has a
newer one. Note the third line: **AD detected and rebuilt the indices itself.**
Common on fresh promotions and self-healing. An offline `ntdsutil` defrag would
rebuild them explicitly, but on an empty lab DC there is nothing to gain.

## "Installation failed" — a batch hiding which member failed

**Symptom:** the Add Roles and Features wizard reported a generic installation
failure. Repeating it failed the same way. No indication of which component
broke.

**Cause:** .NET Framework 3.5 had also been ticked. **.NET 3.5 is a
Features-on-Demand component** — its binaries are not in the local component
store, so Windows tries to fetch them from Windows Update. At that point the DC's
DNS pointed at itself and the DNS role did not yet exist, so the lookup failed.
One component couldn't reach its source, and **the entire batch reported failure**
— masking that AD DS itself was fine.

**Fix:**

```powershell
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
```

Succeeded instantly.

**Lesson: when a batch operation fails, reduce it to one variable.** One
`-Name`, one real error message, three seconds. The same principle as running
three separate pings instead of one connectivity test.

*(If .NET 3.5 is ever genuinely needed, it can be installed from the mounted ISO
without internet: `Install-WindowsFeature Net-Framework-Core -Source D:\sources\sxs`.)*

## The domain controller that was nearly named `WIN-EL9MD23QN91`

**Symptom:** none. Everything worked.

**What was noticed:** the Add Roles wizard's server-selection page displayed the
server as `WIN-EL9MD23QN91` — Windows' random default name. The rename step had
been skipped while the IP had been set.

**Why it mattered:** a domain controller's hostname becomes its **AD computer
object, its SPNs, its DNS SRV records, and the SYSVOL/NETLOGON paths every client
references.** Renaming after promotion requires `netdom computername` with a
careful multi-step sequence, or demote → rename → re-promote.

Caught with one command to spare:

```powershell
Rename-Computer -NewName "CA-DC-01" -Restart
```

**Lesson: verify `hostname` before promoting, not just the IP address.** The
reboot from the rename also cleared a pending-reboot state that had been blocking
role installation — one command fixing two problems.

## Time that was actually a DNS problem

**Symptom:** repeated event log warnings —

```
NtpClient was unable to set a manual peer to use as a time source because of
DNS resolution error on 'time.windows.com,0x8'.
The error was: No such host is known. (0x80072AF9)
```

**Cause:** read the message closely — **"DNS resolution error."** The DC could
not resolve the NTP hostname because forwarders had not been configured yet. It
was never a time problem; it was a DNS problem wearing a time costume.

**Fix:** configure DNS forwarders first. Time then works.

**Second-order gotcha:** even after configuring a peer, `w32tm /query /status`
kept reporting `Source: Local CMOS Clock` and `ReferenceId: 0x4C4F434C ("LOCL")`.
Configuring a peer **does not force an immediate poll**:

```powershell
w32tm /resync /rediscover
```

After that: `Source: time.cloudflare.com`, stratum 4.

**Lesson: read the error text, not just the error category.** "Time sync failed"
and "time sync failed *because DNS*" lead to completely different investigations.

## Duplicate DNS records from mixing statics and DHCP

**Symptom:** a client resolved to the wrong address roughly half the time.

**Cause:** an A record had been created manually for `ca-win-lab → 10.10.1.10`.
The client then received `10.10.1.100` from DHCP and **registered itself** in the
AD-integrated zone. Two A records for one name — DNS round-robins between them,
so half of all lookups returned a dead address.

**The classic "it works sometimes" bug.**

**Fix, and the better pattern:** a **DHCP reservation** rather than either a
manual record or a client-side static. The device gets a predictable address,
DHCP registers exactly one DNS record, and the assignment is queryable from one
place.

*Note: a reservation does not move a client that already holds a lease. Delete
the lease and release/renew.*

## The installer that showed no disks

**Symptom:** Windows Setup reached "Where do you want to install?" and listed
**no drives at all.**

**Cause:** not a fault. Windows has no built-in VirtIO SCSI driver, so it
genuinely cannot see a VirtIO disk.

**Fix:** *Load driver* → the `virtio-win.iso` attached as a second CD →
`vioscsi\2k22\amd64`. The disk appears immediately.

**Worth attaching that ISO before first boot** — discovering you need it while
staring at an empty disk list means shutting the VM down and starting over.

## Errors that are not errors

- **`Get-ADDomain` → "Unable to find a default server with Active Directory Web
  Services running"** on a server with AD DS installed but **not yet promoted**.
  ADWS only runs on an actual domain controller. Installing the role and
  promoting are two separate acts; this error is the correct answer to "am I a DC
  yet?"
- **`Add-DhcpServerv4Reservation` → `ResourceExists` / `DHCP 20022`** means the
  reservation already exists. The command refused to create a duplicate rather
  than failing to do the work.
- **The DNS delegation warning during promotion.** It reports that no parent zone
  delegates `casey.corp` to this server. There is no parent — it's a private,
  self-contained namespace. Expected.
