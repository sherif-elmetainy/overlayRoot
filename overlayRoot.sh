#!/usr/bin/env bash
#  Read-only Root-FS for Raspian using overlayfs
#
#  Created 2017 by Pascal Suter @ DALCO AG, Switzerland to work on Raspian as custom init script
#  (raspbian does not use an initramfs on boot)
#  Modifications listed as 1.2 Mark Lister: github.com/marklister
#  Modified by Sherif Elmetainy: github.com/sherif-elmetainy
#
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see
#    <http://www.gnu.org/licenses/>.
#
#
#  Tested with Raspbian mini, 2018-10-09
#
#  This script will mount the root filesystem read-only and overlay it with a temporary tempfs
#  which is read-write mounted. This is done using the overlayFS which is part of the linux kernel
#  since version 3.18.
#  when this script is in use, all changes made to anywhere in the root filesystem mount will be lost
#  upon reboot of the system. The SD card will only be accessed as read-only drive, which significantly
#  helps to prolong its life and prevent filesystem coruption in environments where the system is usually
#  not shut down properly
#

_defaults(){

    # OverlayRoot config file  override these defaults in /etc/overlayRoot.conf

    # What to do if the script fails
    # original = run the original /sbin/init
    # console = start a bash console. Useful for debugging

    ON_FAIL=original

    # Discover the root device using PARTUUID=xxx UUID=xxx or LABEL= xxx  if the fstab detection fails.
    # Note PARTUUID does not work at present.
    # Default is "LABEL=rootfs".  This makes the script work out of the box

    SECONDARY_ROOT_RESOLUTION="LABEL=rootfs"

    # The filesystem name to use for the RW partition
    # Default root-rw

    RW_NAME=root-rw

    # Discover the rw device using PARTUUID=xxx UUID=xxx or LABEL= xxx  if the fstab detection fails.
    # Note PARTUUID does not work at present.
    # Default is "LABEL=root-rw".  This makes the script work out of the box if the user labels their partition

    SECONDARY_RW_RESOLUTION="LABEL=root-rw"

    # What to do if the user has specified rw media in fstab and it is not found using primary and secondary lookup?
    # fail = follow the fail logic see ON_FAIL
    # tmpfs = mount a tmpfs at the root-rw location Default

    ON_RW_MEDIA_NOT_FOUND=tmpfs

    LOGGING=warning

    LOG_FILE=/var/log/overlayRoot.log

    #Jumper this pin to ground to disable rootOverlay
    GPIO_DISABLE=4

    # Jumper this pin to ground to boot to an emergency bash console
    GPIO_CONSOLE=1

    #Read the selected configuration
    source /etc/overlayRoot.conf
}

function _log_fail
{
    echo -e "[FAIL:overlay] $@" | tee -a /mnt/overlayRoot.log
    ((FAILURES++))
}

function _log_warning
{
    if [ $LOGGING == "warning" ] || [ $LOGGING == "info" ]; then
        echo -e "[FAIL:overlay] $@" | tee -a /mnt/overlayRoot.log
    fi
    ((WARNINGS++))
}

function _log_info
{
    if [ $LOGGING == "info" ]; then
        echo -e "[INFO:overlay] $1" | tee -a /mnt/overlayRoot.log
    fi
}

function _fail
{
    _log_fail $@
    if [ $ON_FAIL == "original" ]; then
        exec /sbin/init
        exit 0
    elif [ $ON_FAIL == "console" ]; then
    # if this appears to hang your machine make sure your active console is the last 'console=' entry
    # in /boot/cmdline.txt
        exec /bin/bash # one can "exit" to original boot process
        exec /bin/init
    else
        exec /bin/bash
    fi
}

function _checkUsbDevice
{
    local usb_device=$1
    _log_info "Checking USB Device $usb_device";
    _await_device $usb_device 20
    _log_info "Wait for device complete $usb_device";
    test -e $usb_device
    if [ $? -eq 0 ]; then
        _log_info "$usb_device appeared";
    else
        _log_warning "$usb_device did not appear after 20 seconds";
        exec /bin/init
        _fail
    fi
    
    local last_part=$(parted -m ${usb_device} unit s print | tail -1)
    local partition_count=$(echo $last_part | cut -f1 -d:)
    local partition_type=$(echo $last_part | cut -f5 -d:)
    _log_info "Device $usb_device has $partition_count partitions."
    _log_info "Device $usb_device partition $partition_count is of type: $partition_type."

    if [ "$partition_count" != "1" ] || [ "$partition_type" != "ext4" ]
    then
        _log_info "Device ${usb_device} has ${partition_count} and last partition is ${partition_type}. It must contain exactly 1 partition of type exfat. RECREATING."
        _recreatePartition ${usb_device}
    fi
}

function _recreatePartition
{
    local usb_device=$1
    _log_info "Removing existing partitions from ${usb_device} and creating one linux partition."
    fdisk ${usb_device} > /dev/null <<EOT
o
n
p
1


t
83
w
EOT
    _log_info "FDISK completed! Created one partition on ${usb_device}."

    _log_info "Formatting partition on ${usb_device}1."
    mkfs.ext4 -F -F ${usb_device}1
    _log_info "Format done on ${usb_device}1."
}

#Wait for a device to become available
# $1 device
# $2 timeout
function _await_device
{
    count=0
    if [ -z $2 ]; then TIMEOUT=60; else TIMEOUT=$2; fi
    result=1
    while [ $count -lt $TIMEOUT ];
    do
        _log_info "Waiting for device $1 $count";
        test -e $1
        if [ $? -eq 0 ]; then
            _log_info "$1 appeared after $count seconds";
            result=0
            break;
        fi
        sleep 1;
        ((count++))
    done
    return $result
}

# Run the command specified in $1. Log the result. If the command fails and safe is selected abort to /bin/init
# Otherwise drop to a bash prompt.
function _run_protected_command
{
    _log_info "Run: $1"
    eval $1
    if [ $? -ne 0 ]; then
        _log_fail "ERROR: error executing $1"
    fi
}

source ./usr/share/initramfs-tools/scripts/functions  #we use read_fstab_entry and resolve_device
function _main
{
    _defaults
    rootmnt=""
    RW="/mnt/$RW_NAME"  # Mount point for writable drive

    FAILURES=0
    WARNINGS=0




    ################## BASIC SETUP & JUMPER DETECTION##############################################################

    _run_protected_command "mount -t proc proc /proc"
    _run_protected_command "mount -t tmpfs inittemp /mnt"
    _run_protected_command "modprobe overlay"

    gpio mode $GPIO_DISABLE up  # activate pull up resistor  ground is just above pin 4
    gpio mode $GPIO_CONSOLE up

    if [[ $(gpio read $GPIO_DISABLE) = 0 ]]; then
        _log_info "Jumper on GPIO $GPIO_DISABLE overlayRoot -- will run /sbin/init directly"
        exec /sbin/init
        exit 0
    elif [[ $(gpio read $GPIO_CONSOLE) = 0 ]]; then
        _log_info "Jumper on GPIO $GPIO_CONSOLE overlayRoot -- dropping straight to bash shell"
        exec /bin/bash
        exit 0
    else
        _log_info "No jumper detected on $GPIO_CONSOLE or $GPIO_DISABLE-- continuing overlayRoot"
    fi
    ######################### PHASE 1 DATA COLLECTION #############################################################

    # ROOT
    read_fstab_entry "/"
    _log_info "Found $MNT_FSNAME for root"
    resolve_device $MNT_FSNAME
    _log_info "Resolved [$MNT_FSNAME] as [$DEV]"
    if [ -z $DEV ]; then
        resolve_device $SECONDARY_ROOT_RESOLUTION
        _log_info "Resolved device [$SECONDARY_ROOT_RESOLUTION] as [$DEV]"
    fi

    if [ -z $DEV ];  then
        _log_fail "Can't resolve root device from [$MNT_FSNAME] or [$SECONDARY_ROOT_RESOLUTION].  Try changing entry to UUID or plain device"
    fi

    if ! test -e $DEV; then
        _log_fail "Resolved root to $DEV but can't find the device"
    fi


    ROOT_MOUNT="mount -t $MNT_TYPE -o $MNT_OPTS,ro $DEV /mnt/lower"

    # ROOT-RW
    if read_fstab_entry $RW; then
        _log_info "found fstab entry for $RW"
        # Things don't go well if usb is not up or fsck is being performed
        # kludge -- wait for /dev/sda1
        
        _checkUsbDevice "/dev/sda"
        _await_device "/dev/sda1"  20  #Wait a generous amount of time for first device
        if ! resolve_device $MNT_FSNAME; then
            #_log_info "No device found for $RW going to try for /dev/sdb1..."
            DEV="/dev/sdb1"
        fi
        #This time we are hopefully waiting for the actual device not /dev/sdb1
        _await_device "$DEV" 5
        #Retry the lookup


        resolve_device $MNT_FSNAME
        _log_info "Resolved [$MNT_FSNAME] as [$DEV]"
        if [ -z $DEV ]; then
            resolve_device $SECONDARY_RW_RESOLUTION
            _log_info "Resolved [$SECONDARY_RW_RESOLUTION] as [$DEV]"
        fi
        _await_device "$DEV" 20


        if [ -n $DEV ] && [ -e "$DEV" ]; then

                RW_MOUNT="mount -t $MNT_TYPE -o $MNT_OPTS $DEV $RW"

        else
            if ! test -e $DEV; then
                _log_warning "Resolved root to $DEV but can't find the device"
            fi
            if [ $ON_RW_MEDIA_NOT_FOUND == "tmpfs" ]; then
                _log_warning "Could not resolve the RW media or find it on $DEV"
                RW_MOUNT="mount -t tmpfs emergency-root-rw $RW"
            else
                _log_fail "Rw media required but not found"
            fi
        fi
    else
        _log_info "No rw fstab entry, will mount a tmpfs"
        RW_MOUNT="mount -t tmpfs tmp-root-rw $RW"
    fi

    ####################### PHASE 2 SANITY CHECK AND ABORT HANDLING ###############################################

    if [ $FAILURES -gt 0 ]; then
        _fail "Fix $FAILURES failures and maybe $WARNINGS warnings before overlayRoot will work"
    fi

    ###################### PHASE 3 ACTUALLY DO STUFF ##############################################################

    # create a writable fs to then create our mountpoints
    mkdir /mnt/lower
    mkdir /mnt/root-rw
    mkdir /mnt/newroot

    _run_protected_command "$RW_MOUNT"
    _run_protected_command "$ROOT_MOUNT"

    mkdir -p $RW/upper
    mkdir -p $RW/work

    _run_protected_command "mount -t overlay -o lowerdir=/mnt/lower,upperdir=$RW/upper,workdir=$RW/work overlayfs-root /mnt/newroot"


    # create mountpoints inside the new root filesystem-overlay
    mkdir -p /mnt/newroot/ro
    mkdir -p /mnt/newroot/rw

    # remove root mount from fstab (this is already a non-permanent modification)
    grep -v "$DEV" /mnt/lower/etc/fstab > /mnt/newroot/etc/fstab
    echo "#the original root mount has been removed by overlayRoot.sh" >> /mnt/newroot/etc/fstab
    echo "#this is only a temporary modification, the original fstab" >> /mnt/newroot/etc/fstab
    echo "#stored on the disk can be found in /ro/etc/fstab" >> /mnt/newroot/etc/fstab
    # change to the new overlay root
    cd /mnt/newroot
    cat /mnt/overlayRoot.log >> /mnt/newroot/$LOG_FILE
    pivot_root . mnt
exec chroot . sh -c "$(cat <<EOT
# move ro and rw mounts to the new root
mount --move /mnt/mnt/lower/ /ro
if [ $? -ne 0 ]; then
    echo "ERROR: could not move ro-root into newroot"
    /bin/bash
fi
mount --move /mnt/$RW /rw
if [ $? -ne 0 ]; then
    echo "ERROR: could not move tempfs rw mount into newroot"
    /bin/bash
fi
# unmount unneeded mounts so we can unmout the old readonly root
umount /mnt/mnt
umount /mnt/proc
umount /mnt/dev
umount /mnt
# continue with regular init
exec /sbin/init
EOT
)"
}

_main