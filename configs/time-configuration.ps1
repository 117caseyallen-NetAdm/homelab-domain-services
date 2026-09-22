# Time configuration - run on the PDC emulator ONLY
#
# Kerberos fails outside +/- 5 minutes of clock skew, and those failures present
# as permission errors rather than time errors. Time is infrastructure.
#
# State as of 2026-09-13: the PDC emulator follows four external stepping
# sources (one of them stratum 1) and is stratum 2. Every domain member follows
# it automatically. Every NETWORK DEVICE follows it explicitly - config at the
# bottom of this file. Verified output for all of it is in the hub repo:
# casey-lab/docs/verification.md, section 6.

# --- Why only this machine --------------------------------------------------
# Domain members follow the domain hierarchy to the PDC emulator automatically -
# no client configuration needed. The PDC emulator is the ONLY machine that
# needs manual setup, because it sits at the top of that hierarchy with nothing
# above it to sync from.
#
# That is exactly what W32Time reports at promotion:
#
#   "This machine is configured to use the domain hierarchy to determine its
#    time source, but it is the AD PDC emulator for the domain at the root of
#    the forest, so there is no machine above it in the domain hierarchy to use
#    as a time source."

# --- Multiple peers, ONE leap-second family ---------------------------------
# A single NTP source is an undetectable single point of failure. NTP's
# selection algorithm exists to compare several servers and exclude a
# "falseticker" - one confidently reporting the wrong time. With one peer there
# is nothing to compare against and you follow it wherever it goes.
#
# LEAP SECOND HANDLING - pick one family, do not mix:
#
#   Smearing  (spread a leap second over ~24h): Cloudflare, Google, AWS
#   Stepping  (apply it instantly):             NIST, most of pool.ntp.org
#
# Mixed families genuinely disagree by up to a second during a leap event, and
# the selection algorithm may discard healthy peers. Rare, and miserable to
# diagnose when it happens. This build uses the all-STEPPING family, keeping
# time.nist.gov because it is a stratum-1 (radio clock) reference - the DC
# re-selected it on its own within minutes of being given the choice.
#
# 0x8 = client mode, normal polling. /reliable:yes advertises this DC as a
# reliable source - correct on the PDC emulator, WRONG on any other DC.

w32tm /config /manualpeerlist:"time.nist.gov,0x8 0.pool.ntp.org,0x8 1.pool.ntp.org,0x8 2.pool.ntp.org,0x8" `
      /syncfromflags:manual /reliable:yes /update

Restart-Service w32time

# --- This step is required --------------------------------------------------
# Configuring a peer does NOT force an immediate poll. Without this, status
# keeps reporting "Local CMOS Clock" and it looks like the config was ignored.

w32tm /resync /rediscover

# --- Verify -----------------------------------------------------------------
# Want: Stratum 2 or 3, Source naming one of the peers, ReferenceId showing its
# address. NOT ReferenceId 0x4C4F434C ("LOCL") - that means it is still using
# the local hardware clock and declaring itself authoritative.

w32tm /query /status
w32tm /query /peers

# On any domain member, confirm it inherited the hierarchy - the HAS_TIMESERV
# flag means the DC is serving it time:
#
#   nltest /sc_query:casey.corp
#   Flags: 30 HAS_IP  HAS_TIMESERV ...

# --- The DC as an NTP SERVER for non-domain devices -------------------------
# W32Time has independent client and server halves. On a DC the server half is
# on by default, but confirm before pointing switches at it:
#
#   w32tm /query /configuration | findstr /i "announceflags NtpServer Enabled"
#     AnnounceFlags: 5     <- always announce as a reliable source
#     Enabled: 1           <- under [NtpServer]
#   netstat -an | findstr ":123"
#     UDP 0.0.0.0:123      <- actually listening
#
# Firewall: the inbound rule "Active Directory Domain Controller - W32Time
# (NTP-UDP-In)" is Profile=Any, RemoteAddress=Any by default, so devices on the
# management VLAN (a different subnet, no domain membership) can query it.
# Check with:
#   Get-NetFirewallRule -DisplayName "*W32Time*" | Get-NetFirewallAddressFilter
#
# Gotcha found while checking this: a single-DC VM's NIC can land on the PUBLIC
# firewall profile (Get-NetConnectionProfile -> "Unidentified network"), because
# Network Location Awareness races this machine's own DNS service at boot. Every
# Domain-profile rule is inert while that is true. Mitigation:
#   sc.exe config NlaSvc start= delayed-auto     (note the space after start=)
# PowerShell 5.1's Set-Service has no delayed-start value; that enum is PS 7.

# --- Network devices: point at the DC, set UTC ------------------------------
# Every switch and firewall syncs to 10.20.2.5. Devices are set to UTC on
# purpose: local time is not monotonic - DST duplicates an hour every autumn and
# skips one every spring, so local timestamps are neither unique nor ordered
# across those boundaries. Correlating one event across five devices needs a
# clock that never repeats. Windows stays local; that is a translation done
# once, not a landmine twice a year.
#
# Cisco IOS (15.x and 12.1 both accept all of this):
#   ntp server 10.20.2.5
#   clock timezone UTC 0
#   service timestamps log datetime msec show-timezone
#   service timestamps debug datetime msec show-timezone
#   -> the timestamps lines matter as much as the ntp line; default IOS logging
#      shows uptime, not wall time
#
# Arista EOS (needs `enable` first - EOS lands in unprivileged mode):
#   ntp server 10.20.2.5
#   clock timezone UTC
#
# Juniper Junos:
#   set system ntp server 10.20.2.5
#   set system time-zone UTC
#   commit
#
# PAN-OS: Device > Setup > Services > NTP -> Primary 10.20.2.5
#         Device > Setup > Management > General Settings -> Timezone UTC
#
# Verify (IOS/EOS: show ntp associations / show ntp status; Junos: show ntp
# associations; PAN-OS: show ntp). Want the `*` beside 10.20.2.5 - that is the
# peer the system SELECTED, not merely configured - and reach 377 (octal: eight
# consecutive successful polls). reach 0 on a freshly configured peer is normal;
# the poll interval is 64 s, so give it five minutes before diagnosing anything.
#
#   *~10.20.2.5       132.163.97.6     2      9     64   377  1.911  79.158  1.382
#
# The ref clock column shows the DC's OWN upstream (132.163.97.6 = time.nist.gov)
# from the switch - each device can see two levels up the hierarchy.
