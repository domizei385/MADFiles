#!/system/bin/sh
#This is for update_mad version
uver="4.1"
#This is for pingreboot version
pver="2.0"
# mad rom version
madver="1.0"

rgcconf="/data/data/de.grennith.rgc.remotegpscontroller/shared_prefs/de.grennith.rgc.remotegpscontroller_preferences.xml"
pdconf="/data/data/com.mad.pogodroid/shared_prefs/com.mad.pogodroid_preferences.xml"
useragent='Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:53.0) Gecko/20100101 Firefox/53.0'
ip="$(ifconfig 'eth0'|awk '/inet addr/{print $2}'|cut -d ':' -f 2)"

download(){
# $1 = url
# $2 = local path
# lets see that curl exits successfully
until /system/bin/curl -s -k -L -A "$useragent" -o "$2" "$1" ;do
    sleep 15
done
}

log_msg() {
# $1 = severity
# $2 = msg
if [[ "$session_id" ]] ;then
    echo "$msg"
    /system/bin/curl -s -k -L -d "$1,$2" --user "$pdauth" -H 'Content-Type: text/html' "${pdserver}/autoconfig/${session_id}/log"
fi
}


execute_autoupdates(){
if ! grep -q "version $uver" /system/bin/update_mad.sh; then
    download https://raw.githubusercontent.com/C64Axel/MADFiles/master/update_mad.sh /system/bin/update_mad.sh
    chmod +x /system/bin/update_mad.sh
fi
if ! grep -q "version $pver" /system/bin/pingreboot.sh; then
     download https://raw.githubusercontent.com/Map-A-Droid/MAD-ATV/master/pingreboot.sh /system/bin/pingreboot.sh
     chmod +x /system/bin/pingreboot.sh
fi

! [[ -f /sdcard/disableautopogoupdate ]] && sh -x /system/bin/update_mad.sh -p
! [[ -f /sdcard/disableautopogodroidupdate ]] && sh -x /system/bin/update_mad.sh -wd
! [[ -f /sdcard/disableautorgcupdate ]] && sh -x /system/bin/update_mad.sh -wr
}

#don't add it for execution as long as no one else is having issues with wrong language
set_android_language() {
if ! [[ "$(getprop persist.sys.locale)" == "en-US" ]] ;then
 setprop persist.sys.locale en-US; setprop ctl.restart zygote
fi
}

set_mac(){
echo 1 > /sys/class/unifykeys/lock
echo mac > /sys/class/unifykeys/name
echo "$1" >/sys/class/unifykeys/write
cat /sys/class/unifykeys/read
echo 0 > /sys/class/unifykeys/lock
}

getmadminmac(){
all_macs="$(/system/bin/curl -s -k -L --user "$pdauth" -H "origin: $origin" "${pdserver}/autoconfig/mymac")"
interface="$(sed -n 1p <<< "$all_macs")"
mac="$(sed -n 2p <<< "$all_macs")"
}

setmadminmac(){
if [[ "$current_mac" == "00:15:18:01:81:31" ]] ;then
    current_mac=$(xxd -l 6 -p /dev/urandom |sed 's/../&:/g;s/:$//')
        ifconfig eth0 down
    until ifconfig eth0 hw ether "$current_mac" 2>/dev/null; do
        current_mac=$(xxd -l 6 -p /dev/urandom |sed 's/../&:/g;s/:$//')
    done
    ifconfig eth0 up
    sleep 3
fi
/system/bin/curl -s -k -L --user "$pdauth" -H 'Content-Type: text/html' -H "origin: $origin" "${pdserver}/autoconfig/mymac" -d "$current_mac"
getmadminmac
while [[ "$mac" == "" ]] ;do
    # if that mac was not accepted
    current_mac=$(xxd -l 6 -p /dev/urandom |sed 's/../&:/g;s/:$//')
    ifconfig eth0 down
    until ifconfig eth0 hw ether "$current_mac" 2>/dev/null; do
        current_mac=$(xxd -l 6 -p /dev/urandom |sed 's/../&:/g;s/:$//')
    done
    ifconfig eth0 up
    sleep 3
    # set a new one
    /system/bin/curl -s -k -L --user "$pdauth" -H 'Content-Type: text/html' -H "origin: $origin" "${pdserver}/autoconfig/mymac" -d "$current_mac"
    # check again
    getmadminmac
done
}

checkmac(){
if [[ "$(/system/bin/curl -s -k -L -o /dev/null -w "%{http_code}" --user "$pdauth" -H "origin: $origin" "${pdserver}/autoconfig/mymac")" == "200" ]] ;then
    if ifconfig|grep -A5 wlan0|grep -q inet ;then
        current_mac=$(ifconfig wlan0|awk '/HWaddr/{print $5}')
    elif ifconfig|grep -A5 eth0|grep -q inet ;then
        current_mac=$(ifconfig eth0|awk '/HWaddr/{print $5}')
        getmadminmac
        echo "MAD-assigned MAC: \"$mac\""
        echo "Current MAC: \"$current_mac\""
        if [[ "$mac" == "" ]] ;then
            # use our current mac for now on
            setmadminmac
            set_mac "$current_mac"
        elif [[ "$mac" != "$current_mac" ]] ;then
            #use the mac suppplied from madmin
            set_mac "$mac"
        fi
    fi
else
    echo "Maybe the origin $origin does not exist in madmin or something?"
fi
}

wait_for_network(){
echo "Waiting for network"
until ping -c1 8.8.8.8 >/dev/null 2>/dev/null; do
    "No network detected.  Sleeping 10s"
    sleep 10
done
echo "Network connection detected"
}

test_session(){
[[ "$session_id" ]] || return 5
case "$(/system/bin/curl -s -k -L -o /dev/null -w "%{http_code}" --user "$pdauth" "${pdserver}/autoconfig/${session_id}/status")" in
 406) sleep 15 && test_session
   ;;
 40*) return 3
   ;;
 200) return 0
   ;;
  "") return 2
   ;;
   *) echo "unexpected status $(/system/bin/curl -s -k -L -o /dev/null -w "%{http_code}" --user "$pdauth" "${pdserver}/autoconfig/${session_id}/status") from madmin" && return 4
   ;;
esac
}

make_session(){
until test_session ;do
    echo "Trying to register session"
    session_id=$(/system/bin/curl -s -k -L -X POST --user "$pdauth" "${pdserver}/autoconfig/register")
    sleep 15
done
echo "$session_id" > /sdcard/reg_session
}

check_session(){
if ! [[ -f /sdcard/reg_session ]] ;then
    make_session
else
    session_id="$(cat /sdcard/reg_session)"
    if ! test_session ;then
        rm -f /sdcard/reg_session
        make_session
    fi
fi
}

################ start of execution

if ! [[ -f /data/local/tmp/init/initend ]] ;then
   exit
fi

sleep 20 # in case mounting /sdcard and usb takes awhile
wait_for_network
if [[ -f "$pdconf" ]] ;then
    origin="$(awk -F'>' '/post_origin/{print $2}' "$pdconf"|awk -F'<' '{print $1}')"
    pdserver="$(grep -v raw "$pdconf"|awk -F'>' '/post_destination/{print $2}'|awk -F'<' '{print $1}')"
    pduser="$(grep -v raw "$pdconf"|awk -F'>' '/auth_username/{print $2}'|awk -F'<' '{print $1}')"
    pdpass="$(grep -v raw "$pdconf"|awk -F'>' '/auth_password/{print $2}'|awk -F'<' '{print $1}')"
    pdauth="$pduser:$pdpass"
    ### PlayStore is needed for Play Integrity so let's change this to enabled rather than deleting whole line
    ### and making people run two jobs - ROM update & enabling PlayStore
    pm enable com.android.vending
    [[ -f /sdcard/reg_session ]] && check_session
elif [[ -f /data/local/pdconf ]] ;then
    origin="$(awk -F'>' '/post_origin/{print $2}' /data/local/pdconf|awk -F'<' '{print $1}')"
    pdserver="$(grep -v raw /data/local/pdconf|awk -F'>' '/post_destination/{print $2}'|awk -F'<' '{print $1}')"
    pduser="$(grep -v raw /data/local/pdconf|awk -F'>' '/auth_username/{print $2}'|awk -F'<' '{print $1}')"
    pdpass="$(grep -v raw /data/local/pdconf|awk -F'>' '/auth_password/{print $2}'|awk -F'<' '{print $1}')"
    pdauth="$pduser:$pdpass"
    check_session
else
#    usbfile="$(find /mnt/media_rw/ -name mad_autoconf.txt|head -n1)"
    usbfile="/data/local/tmp/mad_autoconf.txt"
    if [[ "$usbfile" ]] ;then
        pdserver="$(awk 'NR==1{print $1}' "$usbfile")"
        pdauth="$(awk 'NR==2{print $1}' "$usbfile")"
        check_session
        origin=$(/system/bin/curl -s -k -L --user "$pdauth" "${pdserver}/autoconfig/${session_id}/origin")
        log_msg 2 "Hello, this is 42installmad from $origin! My current IP is $ip"
        /system/bin/curl -s -k -L -o "/data/local/pdconf" --user "$pdauth" "${pdserver}/autoconfig/${session_id}/pd"
        log_msg 2 "PD configuration downloaded to /data/local/pdconf"
        checkmac
        wait_for_network
        ip="$(ifconfig 'eth0'|awk '/inet addr/{print $2}'|cut -d ':' -f 2)"
        log_msg 2 "Check for the need to MAC adress change completed! This may have caused an IP change. My current IP is $ip "
        echo "Installing the apps from the wizard"
        if ! grep -q "version $uver" /system/bin/update_mad.sh; then
            download https://raw.githubusercontent.com/C64Axel/MADFiles/master/update_mad.sh /system/bin/update_mad.sh
            chmod +x /system/bin/update_mad.sh
            log_msg 2 "Installed /system/bin/update_mad.sh"
        fi
        log_msg 2 "Starting install of RGC, PoGo and PD from your madmin wizard"
        log_msg 2 "Installing RGC"
		sh -x /system/bin/update_mad.sh -pdc -wr
        log_msg 2 "Installing PoGo"
		sh -x /system/bin/update_mad.sh -pdc -p
        log_msg 2 "Installing PD"
		sh -x /system/bin/update_mad.sh -pdc -wd
    fi
fi

[[ $(settings get global hdmi_control_enabled) != "0" ]] && settings put global hdmi_control_enabled 0
[[ $(settings get global stay_on_while_plugged_in) != 3 ]] && settings put global stay_on_while_plugged_in 3
[[ "$(/system/bin/appops get de.grennith.rgc.remotegpscontroller android:mock_location)" = "No operations." ]] && /system/bin/appops set de.grennith.rgc.remotegpscontroller android:mock_location allow
! settings get secure location_providers_allowed|grep -q gps && settings put secure location_providers_allowed +gps
echo "$madver" > /sdcard/madversion

log_msg 2 "Configuring RGC and PD, setting permissions"
pdir="/data/data/com.mad.pogodroid/"
puser="$(stat -c %u "$pdir")"
rgcdir="/data/data/de.grennith.rgc.remotegpscontroller/"
ruser="$(stat -c %u "$rgcdir")"
if [[ "$puser" ]] && [[ "$pdauth" ]] && [[ -d "$pdir" ]] && ! [[ -f "$pdconf" ]] && [[ "$session_id" ]] ;then
    if [[ ! -d "$pdir/shared_prefs" ]] ;then
        mkdir -p "$pdir/shared_prefs"
        chmod 771 "$pdir/shared_prefs"
        chown "$puser":"$puser" "$pdir/shared_prefs"
    fi
    /system/bin/curl -s -k -L -o "$pdconf" --user "$pdauth" "${pdserver}/autoconfig/${session_id}/pd"
    chmod 660 "$pdconf" && chown "$puser":"$puser" "$pdconf"
    rm -f /data/local/pdconf
    log_msg 2 "PD configuration downloaded and installed"
fi
if [[ "$puser" ]] && [[ "$pdauth" ]] && [[ -d "$rgcdir" ]] && ! [[ -f "$rgcconf" ]] ;then
    if [[ ! -d "$rgcdir/shared_prefs" ]] ;then
        mkdir -p "$rgcdir/shared_prefs"
        chmod 771 "$rgcdir/shared_prefs"
        chown "$ruser":"$ruser" "$rgcdir/shared_prefs"
    fi
    /system/bin/curl -s -k -L -o "$rgcconf" --user "$pdauth" "${pdserver}/autoconfig/${session_id}/rgc"
    chmod 660 "$rgcconf" && chown "$ruser":"$ruser" "$rgcconf"
    log_msg 2 "RGC configuration downloaded and installed"
fi
if [[ "$(pm list packages com.mad.pogodroid)" ]] && ! dumpsys package com.mad.pogodroid |grep READ_EXTERNAL_STORAGE|grep granted|grep -q 'granted=true'; then
    pm grant com.mad.pogodroid android.permission.READ_EXTERNAL_STORAGE
    pm grant com.mad.pogodroid android.permission.WRITE_EXTERNAL_STORAGE
fi
if [[ "$(pm list packages com.nianticlabs.pokemongo)" ]] && ! dumpsys package com.nianticlabs.pokemongo|grep ACCESS_FINE_LOCATION|grep granted|grep -q 'granted=true'; then
    pm grant com.nianticlabs.pokemongo android.permission.ACCESS_FINE_LOCATION
    pm grant com.nianticlabs.pokemongo android.permission.ACCESS_COARSE_LOCATION
    pm grant com.nianticlabs.pokemongo android.permission.CAMERA
    pm grant com.nianticlabs.pokemongo android.permission.GET_ACCOUNTS
fi
if [[ "$(pm list packages de.grennith.rgc.remotegpscontroller)" ]] && ! dumpsys package de.grennith.rgc.remotegpscontroller|grep ACCESS_FINE_LOCATION|grep granted|grep -q 'granted=true'; then
    pm grant de.grennith.rgc.remotegpscontroller android.permission.ACCESS_FINE_LOCATION
    pm grant de.grennith.rgc.remotegpscontroller android.permission.READ_EXTERNAL_STORAGE
    pm grant de.grennith.rgc.remotegpscontroller android.permission.ACCESS_COARSE_LOCATION
    pm grant de.grennith.rgc.remotegpscontroller android.permission.WRITE_EXTERNAL_STORAGE
fi

# Hiding NAV Bar 
/system/bin/settings put global policy_control immersive.status=*

if [[ -f /sdcard/reg_session ]] && [[ -f "$pdconf" ]] && [[ -f "$rgcconf" ]] ;then
    /system/bin/curl -s -k -L -X DELETE --user "$pdauth" "${pdserver}/autoconfig/${session_id}/complete"
    rm -f /sdcard/reg_session
    monkey -p com.mad.pogodroid 1
    sleep 10
    monkey -p de.grennith.rgc.remotegpscontroller 1
    sleep 10
    reboot
fi
execute_autoupdates

# initdebug