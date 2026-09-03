# Time configuration - run on the PDC emulator ONLY
#
# Kerberos fails outside +/- 5 minutes of clock skew, and those failures present
# as permission errors rather than time errors. Time is infrastructure.

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

w32tm /config /manualpeerlist:"time.cloudflare.com,0x8" `
      /syncfromflags:manual /reliable:yes /update

Restart-Service w32time

# --- This step is required --------------------------------------------------
# Configuring a peer does NOT force an immediate poll. Without this, status
# keeps reporting "Local CMOS Clock" and it looks like the config was ignored.

w32tm /resync /rediscover

# --- Verify -----------------------------------------------------------------
# Want: Source naming the external peer, and ReferenceId showing its address.
# NOT ReferenceId 0x4C4F434C ("LOCL"), which means it is still using the local
# hardware clock and declaring itself authoritative.

w32tm /query /status
w32tm /query /peers

# On any domain member, confirm it inherited the hierarchy - the HAS_TIMESERV
# flag means the DC is serving it time:
#
#   nltest /sc_query:casey.corp
#   Flags: 30 HAS_IP  HAS_TIMESERV ...


# --- Improvement not yet applied --------------------------------------------
# A single NTP source is an undetectable single point of failure. NTP's
# algorithm exists to compare multiple servers and identify a "falseticker" - a
# server confidently reporting the wrong time. With one peer there is nothing to
# compare against and you follow it wherever it goes. Three or four is standard.
#
# LEAP SECOND HANDLING - pick one family, do not mix:
#
#   Smearing  (spread a leap second over ~24h): Cloudflare, Google, AWS
#   Stepping  (apply it instantly):             NIST, most of pool.ntp.org
#
# Mixing the two means that during a leap second your sources genuinely disagree
# by up to a second, and NTP's selection algorithm may discard perfectly healthy
# peers. Rare, but it is the kind of fault that only appears once every few years
# and is miserable to diagnose.
#
# Since this DC already uses Cloudflare, the consistent choice is other smearing
# sources:
#
#   w32tm /config /manualpeerlist:"time.cloudflare.com,0x8 time.google.com,0x8 time1.google.com,0x8" /syncfromflags:manual /reliable:yes /update
#
# The all-stepping alternative would be time.nist.gov plus pool.ntp.org servers,
# dropping Cloudflare entirely.
#
# Also outstanding: network devices (switches, firewalls) are not yet in this
# hierarchy and drift independently. That directly damages log correlation -
# tracing one event across five devices requires their clocks to agree.
