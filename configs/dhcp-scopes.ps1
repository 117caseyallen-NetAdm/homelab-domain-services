# DHCP configuration - one server, two sites
# Run on the domain controller. Pairs with configs/3560cg-1-dhcp-relay.txt.

# --- Install and authorize --------------------------------------------------
# Authorization is an AD safety feature: a Windows DHCP server refuses to lease
# addresses on a domain network until it is registered in Active Directory.
# It is how the directory prevents a rogue DHCP server from poisoning clients.

Install-WindowsFeature -Name DHCP -IncludeManagementTools
Add-DhcpServerInDC -DnsName ca-dc-01.casey.corp -IPAddress 10.20.2.5
Get-DhcpServerInDC

# --- WEST, VLAN 20 - the server's own subnet --------------------------------
# No relay needed here: the server sits on this subnet, so client broadcasts
# reach it directly.

Add-DhcpServerv4Scope -Name "WEST-VLAN20-Data" `
    -StartRange 10.20.2.100 -EndRange 10.20.2.199 `
    -SubnetMask 255.255.255.0 -State Active

Set-DhcpServerv4OptionValue -ScopeId 10.20.2.0 `
    -Router 10.20.2.1 -DnsServer 10.20.2.5 -DnsDomain casey.corp

Set-DhcpServerv4Scope -ScopeId 10.20.2.0 -LeaseDuration 1.00:00:00

# --- EAST, VLAN 10 - served across OSPF and the IPsec tunnel ----------------
# This scope exists on a server with NO interface on this subnet, at a
# different site. It is selected by the giaddr field stamped in by the relay
# agent (see 3560cg-1-dhcp-relay.txt).
#
# If this scope did not exist, the server would SILENTLY IGNORE relayed
# requests from that subnet - no error, no useful log entry.

Add-DhcpServerv4Scope -Name "EAST-VLAN10-Data" `
    -StartRange 10.10.1.100 -EndRange 10.10.1.199 `
    -SubnetMask 255.255.255.0 -State Active

Set-DhcpServerv4OptionValue -ScopeId 10.10.1.0 `
    -Router 10.10.1.1 -DnsServer 10.20.2.5 -DnsDomain casey.corp

Set-DhcpServerv4Scope -ScopeId 10.10.1.0 -LeaseDuration 1.00:00:00

# Ranges start at .100 so .1-.99 remains available for static assignment.
# Lease shortened from the 8-day default for lab churn.

# --- Reservations over client-side statics ----------------------------------
# A reservation gives a device a predictable address while keeping the
# assignment in one queryable place, rather than typed into a machine you would
# have to log into to discover. Only infrastructure that must work WHEN DHCP IS
# DOWN - switches, firewalls, the DC itself - stays genuinely static.
#
# A reservation does not move a client that already holds a lease: delete the
# lease, then release/renew on the client.
#
# NOTE ON RANGES: this reserves .10, which sits below the scope's .100-.199 lease
# range. That was accepted here, but Microsoft's documented pattern is for a
# reservation to fall INSIDE the scope range, with exclusions carving out the
# static band. If your build rejects the call, widen the scope and exclude:
#
#   Add-DhcpServerv4Scope        -StartRange 10.10.1.10  -EndRange 10.10.1.199 ...
#   Add-DhcpServerv4ExclusionRange -ScopeId 10.10.1.0 -StartRange 10.10.1.11 -EndRange 10.10.1.99
#
# That keeps .11-.99 unavailable for dynamic leases while making .10 reservable.

Add-DhcpServerv4Reservation -ScopeId 10.10.1.0 `
    -IPAddress 10.10.1.10 -ClientId "<CLIENT_MAC>" `
    -Name "CA-WIN-LAB" -Description "EAST jumpbox"

# --- Verify -----------------------------------------------------------------

Get-DhcpServerv4Scope
Get-DhcpServerv4OptionValue -ScopeId 10.10.1.0
Get-DhcpServerv4Reservation -ScopeId 10.10.1.0
Get-DhcpServerv4Lease -ScopeId 10.10.1.0        # the cross-site proof
