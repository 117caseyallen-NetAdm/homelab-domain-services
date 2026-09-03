# DNS configuration for casey.corp
# Run on the domain controller after promotion.
# The forward zone is created automatically by dcpromo (AD-integrated).

# --- Forwarders -------------------------------------------------------------
# Clients point ONLY at the DC. The DC forwards everything it isn't
# authoritative for. Never list a public resolver as a client's secondary DNS:
# it will authoritatively answer NXDOMAIN for casey.corp records and produce
# intermittent auth failures that vanish on retry.

Set-DnsServerForwarder -IPAddress 1.1.1.1, 9.9.9.9

# --- Reverse lookup zones ---------------------------------------------------
# Skipped by most homelabs. These are what make firewall and SIEM logs readable
# later - nslookup on an IP returns a name instead of nothing.
# 10.99.0.0/24 covers the firewall management loopbacks, which live in neither
# site's management /24.

Add-DnsServerPrimaryZone -NetworkID "10.20.2.0/24"  -ReplicationScope Domain   # WEST data
Add-DnsServerPrimaryZone -NetworkID "10.10.1.0/24"  -ReplicationScope Domain   # EAST data
Add-DnsServerPrimaryZone -NetworkID "10.99.20.0/24" -ReplicationScope Domain   # WEST mgmt
Add-DnsServerPrimaryZone -NetworkID "10.99.10.0/24" -ReplicationScope Domain   # EAST mgmt
Add-DnsServerPrimaryZone -NetworkID "10.99.0.0/24"  -ReplicationScope Domain   # loopbacks

# --- A records for static infrastructure ------------------------------------
# -CreatePtr populates the matching reverse record in the same command.
# Only devices that must work when DHCP is down are static; everything else
# gets a DHCP reservation instead.

Add-DnsServerResourceRecordA -ZoneName casey.corp -Name "pa440-lab"      -IPv4Address 10.99.0.1   -CreatePtr
Add-DnsServerResourceRecordA -ZoneName casey.corp -Name "srx345-lab"     -IPv4Address 10.99.0.2   -CreatePtr
Add-DnsServerResourceRecordA -ZoneName casey.corp -Name "3560cg-2"       -IPv4Address 10.99.20.1  -CreatePtr
Add-DnsServerResourceRecordA -ZoneName casey.corp -Name "3560cg-1"       -IPv4Address 10.99.10.1  -CreatePtr
Add-DnsServerResourceRecordA -ZoneName casey.corp -Name "arista710p-lab" -IPv4Address 10.99.10.14 -CreatePtr
Add-DnsServerResourceRecordA -ZoneName casey.corp -Name "c2940-lab"      -IPv4Address 10.99.20.20 -CreatePtr
Add-DnsServerResourceRecordA -ZoneName casey.corp -Name "prox-lab"       -IPv4Address 10.99.20.10 -CreatePtr
Add-DnsServerResourceRecordA -ZoneName casey.corp -Name "ca-wg-lab"      -IPv4Address 10.20.2.50  -CreatePtr
Add-DnsServerResourceRecordA -ZoneName casey.corp -Name "ca-centos-lab"  -IPv4Address 10.20.2.10  -CreatePtr

# --- Verify -----------------------------------------------------------------
# Forward: should return the address. Reverse: should return the name.

Resolve-DnsName casey.corp                 # local zone, authoritative
Resolve-DnsName google.com                 # via forwarder
Resolve-DnsName prox-lab.casey.corp        # forward
Resolve-DnsName 10.99.10.14                # reverse -> arista710p-lab.casey.corp
