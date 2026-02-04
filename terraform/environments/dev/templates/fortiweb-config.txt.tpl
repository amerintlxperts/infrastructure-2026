config system global
  set admin-sport 8443
end

config system settings
  set enable-file-upload enable
end

config log disk
  set severity notification
end

config log traffic-log
  set status enable
  set packet-log enable
end

config system interface
  edit port1
    set allowaccess ping https ssh
  next
  edit port2
    set mode dhcp
    set allowaccess ping https
  next
end

config router static
  edit 1
    set dst ${vpc_cidr}
    set device port2
    set gateway ${port2_gateway}
  next
end

config system advanced
  set owasp-top10-compliance enable
end

config system feature-visibility
  set api-gateway enable
  set wad enable
end

config system accprofile
  edit "apiadmin"
    set mntgrp rw
    set admingrp rw
    set sysgrp rw
    set netgrp rw
    set loggrp rw
    set authusergrp rw
    set traroutegrp rw
    set wafgrp rw
    set wadgrp rw
    set wvsgrp rw
    set mlgrp rw
  next
end

config system admin
  edit "apiadmin"
    set password ${api_password}
    set access-profile "apiadmin"
  next
end

config system certificate letsencrypt
  set email ${acme_email}
end
