#/bin/bash
trap "exit 1" TERM
export TOP_PID=$$
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# ==============================================================================
# IMAGE CONFIGURATION
# ==============================================================================
UAVCORE_ARCH="armv6"
UAVCORE_VERSION="13.x"
UAVCORE_SUBVERSION="13.0.3"
UAVCORE_KERNEL_VERSION="5.10.77"
IMG_BLOCKSIZE=512
IMG_BLOCKS=204800 # 512 * 204800 = 104857600 (~100MB)
# ==============================================================================
# WIFI CONFIGURATION
# ==============================================================================
SSID="YOUR_WIFI_NETWORK_SSID"
WLANPASS="YOUR_WIFI_PASSWORD"
WPA_SUPPLICANT_CONF="
ctrl_interface=/var/run/wpa_supplicant
network={
ssid=\"$SSID\"
psk=\"$WLANPASS\"
key_mgmt=WPA-PSK
pairwise=CCMP TKIP
group=CCMP TKIP
}
"
# ==============================================================================
# ==============================================================================
# ==============================================================================
# 
WORK_DIR=./uavCore-$UAVCORE_SUBVERSION
MNT1_DIR="$WORK_DIR/mnt1"
MNT2_DIR="$WORK_DIR/mnt2"
PACKAGES_DIR="$WORK_DIR/pkg"

WGET_OPTS="--continue --proxy=off"

UAVCORE_BASE_URL="http://distro.ibiblio.org/tinycorelinux"
UAVCORE_REPOSITORY_URL="$UAVCORE_BASE_URL/$UAVCORE_VERSION/$UAVCORE_ARCH"
UAVCORE_RELEASES_URL="$UAVCORE_REPOSITORY_URL/releases/RPi"
UAVCORE_PACKAGES_URL="$UAVCORE_REPOSITORY_URL/tcz"
UAVCORE_PACKAGE_EXTESION="tcz"
UAVCORE_RELEASE_URL="$UAVCORE_RELEASES_URL/piCore-$UAVCORE_SUBVERSION.zip"
UAVCORE_KERNEL_SUFFIX="-$UAVCORE_KERNEL_VERSION-piCore"
UAVCORE_LOCAL_PACKAGE_PATH="tce/optional"
UAVCORE_LOCAL_MYDATA="tce/mydata"

UAVCORE_FILESYSTEM_DIR="${WORK_DIR}/filesystem"

UAVCORE_PACKAGES=(	"file"\
					"ncurses"\
					"nano"\
)

UAVCORE_PACKAGES_WLAN_CLIENT=(	"libnl"\
								"libiw"\
								"wireless$UAVCORE_KERNEL_SUFFIX"\
								"wireless_tools"\
								"wpa_supplicant"\
								"openssl"\
								"openssh"\
                                "firmware-rpi3-wireless"\
)


BOOTLOCAL_SCRIPT="#!/bin/sh
/usr/sbin/startserialtty &
echo ondemand > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
/sbin/modprobe i2c-dev
sleep 2
/usr/local/sbin/wpa_supplicant -B -D wext -i wlan0 -c /opt/wpa_supplicant.conf &
/sbin/udhcpc -b -i wlan0 -x hostname:$(/bin/hostname) -p /var/run/udhcpc.wlan0.pid &
/usr/local/etc/init.d/openssh start
"

##############################################################################

UAVCORE_PACKAGES=("${UAVCORE_PACKAGES[@]}" "${UAVCORE_PACKAGES_WLAN_CLIENT[@]}")
DEPENDENCIES=(	"wget"\
				"md5sum"\
				"unzip"\
				"dd"\
				"sudo losetup"\
				"sudo kpartx"\
				"sudo parted"\
				"sudo e2fsck"\
				"sudo resize2fs"\
				"mount"\
				"umount"\
				"cat"\
				"awk"\
				"tar"
)

function prepare_dirs(){
    echo "================================================================================" 
    echo " * Making directories"
    echo "================================================================================" 
    [ -d $WORK_DIR ] || mkdir $WORK_DIR
    [ -d $MNT1_DIR ] || mkdir $MNT1_DIR
    [ -d $MNT2_DIR ] || mkdir $MNT2_DIR
    [ -d $UAVCORE_FILESYSTEM_DIR ] || mkdir $UAVCORE_FILESYSTEM_DIR
    echo "  - OK"    
    echo ""
}

function command_exists() {
    type "$1" &> /dev/null ;
}

function validate_url(){
    if [[ `wget $WGET_OPTS -S --spider $1  2>&1 | grep 'HTTP/1.1 200 OK'` ]]; then return 0; else return 1; fi
}

function check_dependencies(){
    echo "================================================================================" 
	echo " * Checking dependencies"
    echo "================================================================================" 
	for i in "${DEPENDENCIES[@]}"
    	do
    		echo -ne "  - $i"
    		if command_exists $i ; then
    			echo " OK"
    		else
    			echo " ERROR. Please install $i and rerun."
    			kill -s TERM $TOP_PID
    		fi
    done
    echo ""
}

function download_release_maybe(){
    echo "================================================================================" 
    echo " * Downloading uavCore Release"
    echo "================================================================================" 
    cd "$SCRIPT_DIR" > /dev/null
    if validate_url $UAVCORE_RELEASE_URL; then
        echo -ne " * uavCore $UAVCORE_SUBVERSION" "($UAVCORE_RELEASE_URL)"    
        echo ""
        read -n1 -r -p " * Press any key to download..." key
        echo ""
        wget $WGET_OPTS $UAVCORE_RELEASE_URL -P $WORK_DIR &&
        unzip -o "$WORK_DIR/uavCore-$UAVCORE_SUBVERSION.zip" -d $WORK_DIR
        check_release
    else
        echo " * ERROR: $UAVCORE_RELEASE_URL url not available"
        kill -s TERM $TOP_PID
    fi
    echo ""
}

function check_release(){
    echo "================================================================================" 
    echo " * Checking release"
    echo "================================================================================" 
    if [ -f "$WORK_DIR/uavCore-$UAVCORE_SUBVERSION.zip" ]; then 
        cd "$WORK_DIR"
        if md5sum --status -c "uavCore-$UAVCORE_SUBVERSION.img.md5.txt"; then
            echo "  - Release available: $WORK_DIR/uavCore-$UAVCORE_SUBVERSION.img"
        else
            echo "  - Checksum FAILED: uavCore-$UAVCORE_SUBVERSION.img.md5.txt"
            download_release_maybe
        fi
    else 
        download_release_maybe
    fi
    cd "$SCRIPT_DIR" > /dev/null
    echo ""
}

function make_image(){
    echo "================================================================================" 
    echo " * Creating Custom uavCore Image"
    echo "================================================================================" 
    echo "  - generating empty image (be patient)"
    cd "$SCRIPT_DIR" > /dev/null
    sudo touch $WORK_DIR/uavCore-$UAVCORE_SUBVERSION.custom.img
    sudo dd bs=$IMG_BLOCKSIZE count=$IMG_BLOCKS if=/dev/zero of=$WORK_DIR/uavCore-$UAVCORE_SUBVERSION.custom.img
    echo ""    
    echo "  - cloning into custom image (be patient)"
    SRC="$(sudo losetup -f --show $WORK_DIR/uavCore-$UAVCORE_SUBVERSION.img)"
    DEST="$(sudo losetup -f --show $WORK_DIR/uavCore-$UAVCORE_SUBVERSION.custom.img)"
    sudo dd if=$SRC of=$DEST

    echo "  - init custom image loop device"
    sudo losetup -d $SRC $DEST
    
    echo "  - setting up custom image partitions"
    rm -rf "$WORK_DIR/uavCore-$UAVCORE_SUBVERSION.custom.img1"
    rm -rf "$WORK_DIR/uavCore-$UAVCORE_SUBVERSION.custom.img2"
    tmp=$(sudo kpartx -l "$WORK_DIR/uavCore-$UAVCORE_SUBVERSION.custom.img" | awk '{ print $1 }' )
    IFS=$'\n' read -rd '' -a parts <<<"$tmp"

    echo "  - trying kpartx (adding...)"
    sudo kpartx -a "$WORK_DIR/uavCore-$UAVCORE_SUBVERSION.custom.img"
    sleep 3
    ln -s /dev/mapper/${parts[0]} "$WORK_DIR/uavCore-$UAVCORE_SUBVERSION.custom.img1" &> /dev/null
    ln -s /dev/mapper/${parts[1]} "$WORK_DIR/uavCore-$UAVCORE_SUBVERSION.custom.img2" &> /dev/null

    echo "  - resizing custom image partition"
    tmp=$(sudo parted -m -s "$WORK_DIR/uavCore-$UAVCORE_SUBVERSION.custom.img" unit s print | awk --field-separator=":" '{print $2}')
    IFS=$'\n' read -rd '' -a size <<<"$tmp"
    start=${size[2]::-1}
    end=$((${size[0]::-1}-1))

    echo "  - trying parted"
    sudo parted -s "$WORK_DIR/uavCore-$UAVCORE_SUBVERSION.custom.img" unit s rm 2
    sudo parted -s "$WORK_DIR/uavCore-$UAVCORE_SUBVERSION.custom.img" unit s mkpart primary $start $end

    echo "  - trying kpartx (cleaning up...)"
    sudo kpartx -d "$WORK_DIR/uavCore-$UAVCORE_SUBVERSION.custom.img" &> /dev/null
    sleep 3

    echo "  - trying kpartx (adding...)"
    sudo kpartx -a "$WORK_DIR/uavCore-$UAVCORE_SUBVERSION.custom.img"
    sleep 3
    ln -s /dev/mapper/${parts[0]} "$WORK_DIR/uavCore-$UAVCORE_SUBVERSION.custom.img1" &> /dev/null
    ln -s /dev/mapper/${parts[1]} "$WORK_DIR/uavCore-$UAVCORE_SUBVERSION.custom.img2" &> /dev/null

    echo ""
    echo "  - checking filesystem (custom image)"
    sudo e2fsck -f "$WORK_DIR/uavCore-$UAVCORE_SUBVERSION.custom.img2"

    echo ""
    echo "  - resizing filesystem (custom image)"
    sudo resize2fs "$WORK_DIR/uavCore-$UAVCORE_SUBVERSION.custom.img2"
    
    echo ""
    echo "  - mounting partition n. 1 (custom image)"
    sudo mount "$WORK_DIR/uavCore-$UAVCORE_SUBVERSION.custom.img1" $MNT1_DIR
    echo "  - mounting partition n. 2 (custom image)"
    sudo mount "$WORK_DIR/uavCore-$UAVCORE_SUBVERSION.custom.img2" $MNT2_DIR
}

function cleanup(){
    echo "================================================================================" 
    echo " * Cleaning up"
    echo "================================================================================" 
    if [ -d "$MNT1_DIR" ]; then 
        sudo umount "$MNT1_DIR" &> /dev/null
        rm -rf "$MNT1_DIR"
    fi
    if [ -d "$MNT2_DIR" ]; then 
        sudo umount "$MNT2_DIR" &> /dev/null
        rm -rf "$MNT2_DIR"
    fi
    sudo kpartx -d "$WORK_DIR/uavCore-$UAVCORE_SUBVERSION.custom.img" &> /dev/null
    [ -L "$WORK_DIR/uavCore-$UAVCORE_SUBVERSION.custom.img1" ] && rm "$WORK_DIR/uavCore-$UAVCORE_SUBVERSION.custom.img1"
    [ -L "$WORK_DIR/uavCore-$UAVCORE_SUBVERSION.custom.img2" ] && rm "$WORK_DIR/uavCore-$UAVCORE_SUBVERSION.custom.img2"
    #[ -e "$WORK_DIR/uavCore-$UAVCORE_SUBVERSION.zip" ] && rm "$WORK_DIR/uavCore-$UAVCORE_SUBVERSION.zip"
    [ -d "$UAVCORE_FILESYSTEM_DIR" ] && sudo rm -rf "$UAVCORE_FILESYSTEM_DIR" 
    echo "  - OK"    
    echo ""
}

function test_package_urls(){
    echo "================================================================================" 
    echo " * Cheking package URLs"
    echo "================================================================================" 
    for i in "${UAVCORE_PACKAGES[@]}"
    do
        URL="$UAVCORE_PACKAGES_URL/$i.$UAVCORE_PACKAGE_EXTESION"
        echo -ne "  - $i" "($URL)"
        if validate_url $URL; then 
            echo " OK";
        else 
            echo " ERROR: $URL not available"; 
            cleanup
            kill -s TERM $TOP_PID
        fi
    done
}

function get_packages(){
    echo "================================================================================" 
    echo " * Downlaoding packages"
    echo "================================================================================" 
    for i in "${UAVCORE_PACKAGES[@]}"
    do
        URL="$UAVCORE_PACKAGES_URL/$i.$UAVCORE_PACKAGE_EXTESION"
        echo "  - $i" "($URL)"
        if [ -f "$PACKAGES_DIR/$UAVCORE_LOCAL_PACKAGE_PATH/$i.tcz" ]; then
            echo " * Package available: $i"
        else
            sudo wget $WGET_OPTS $URL -P "$PACKAGES_DIR/$UAVCORE_LOCAL_PACKAGE_PATH/"
            sudo wget $WGET_OPTS "$URL.md5.txt" -P "$PACKAGES_DIR/$UAVCORE_LOCAL_PACKAGE_PATH/"
        fi
    done
    echo ""
    echo "  - Copying packages"
    sudo rsync -avz $PACKAGES_DIR/$UAVCORE_LOCAL_PACKAGE_PATH/* $MNT2_DIR/$UAVCORE_LOCAL_PACKAGE_PATH/
    echo "" 
}

function make_onboot_list(){
    echo "================================================================================" 
    echo " * Adding packages to onboot.lst"
    echo "================================================================================" 
    sudo sh -c "> $MNT2_DIR/tce/onboot.lst"
    for i in "${UAVCORE_PACKAGES[@]}"
    do
    	sudo sh -c "echo $i.tcz >> $MNT2_DIR/tce/onboot.lst"
    done
    
    sudo sh -c "echo rng-tools-5.tcz >> $MNT2_DIR/tce/onboot.lst"
    # sudo cat "$MNT2_DIR/tce/onboot.lst"
    echo "  - OK"
    echo ""
}

function config_wpa_supplicant(){
    echo "  - Configuring wpa_supplicant"
    [ -d "$MNT2_DIR/$UAVCORE_LOCAL_MYDATA/opt" ] || sudo mkdir "$MNT2_DIR/$UAVCORE_LOCAL_MYDATA/opt"
    sudo sh -c "echo '$WPA_SUPPLICANT_CONF' > '$MNT2_DIR/$UAVCORE_LOCAL_MYDATA/opt/wpa_supplicant.conf'"
	sudo sh -c "echo -e 'opt/wpa_supplicant.conf' >> '$MNT2_DIR/$UAVCORE_LOCAL_MYDATA/opt/.filetool.lst'"
}

function config_bootlocal(){
    echo "  - Configuring bootlocal.sh"
    sudo sh -c "echo '$BOOTLOCAL_SCRIPT' > '$MNT2_DIR/$UAVCORE_LOCAL_MYDATA/opt/bootlocal.sh'"
}

function make_mydata(){
    echo "================================================================================" 
    echo " * Adjusting mydata.tgz"
    echo "================================================================================" 
    echo "  - Unpacking mydata.tgz"
    [ -d "$MNT2_DIR/$UAVCORE_LOCAL_MYDATA" ] || sudo mkdir "$MNT2_DIR/$UAVCORE_LOCAL_MYDATA"
    sudo tar zxvf "$MNT2_DIR/$UAVCORE_LOCAL_MYDATA.tgz" -C "$MNT2_DIR/$UAVCORE_LOCAL_MYDATA"

    echo ""
    config_wpa_supplicant
    config_bootlocal
    echo "  - finalizing"
    cd "$MNT2_DIR/$UAVCORE_LOCAL_MYDATA"
    sudo tar -zcf ../mydata.tgz .
    cd "$SCRIPT_DIR" &> /dev/null
    echo ""
}

function extract_filesystem(){
    echo "================================================================================" 
    echo " * Unpacking filesystem"
    echo "================================================================================" 
    echo "  - fixing permissions"
    sudo sh -c "chmod a+rwx $UAVCORE_FILESYSTEM_DIR"
    echo "  - extracting"
    sudo sh -c "zcat ${MNT1_DIR}/${UAVCORE_SUBVERSION}.gz | (cd $UAVCORE_FILESYSTEM_DIR && sudo cpio -i -H newc -d)"
    echo ""
}

function rebuild_filesystem(){
    echo "================================================================================" 
    echo " * Rebuilding filesystem"
    echo "================================================================================" 
    sudo sh -c "(cd $UAVCORE_FILESYSTEM_DIR && find | cpio -o -H newc) | gzip -2 > ${MNT1_DIR}/${UAVCORE_SUBVERSION}.gz"
    echo ""
    echo " * Custom image: $WORK_DIR/uavCore-$UAVCORE_SUBVERSION.custom.img" 
    echo ""
}

function patch_startserialtty(){
    echo "================================================================================" 
    echo " * Patching startserialtty"
    echo "================================================================================" 
    # piCore 9.0.3 /usr/sbin/startserialtty misses support for RPi Zero W's
    # serial configuration, which is like RPi 3, not like RPi 1/2/Zero:
    # Console is on /dev/ttyS0, not /dev/ttyAMA0

    # maybe RPi Zero W support will be fixed in piCore 9.0.>3, so check, if it
    # is already done
    ZERO_W_SUPPORT=$(grep "Raspberry Pi Zero W" ${UAVCORE_FILESYSTEM_DIR}/usr/sbin/startserialtty)

    if [ "$ZERO_W_SUPPORT"  = "" ] ; then
      echo " - Patching ${UAVCORE_FILESYSTEM_DIR}/usr/sbin/startserialtty) for Raspberry Pi Zero W support"

cat <<EOF > "${WORK_DIR}/startserialtty.patch"
--- usr/sbin/startserialtty    2019-01-22 16:53:14.083585562 +0100
+++ usr/sbin/startserialtty    2019-01-22 16:54:50.906230844 +0100
@@ -4,6 +4,8 @@
 
 if [ "${model:0:20}" = "Raspberry Pi 3 Model" ]; then
     port=ttyS0
+elif [ "\${model:0:19}" = "Raspberry Pi Zero W" ]; then
+    port=ttyS0
 else
     port=ttyAMA0
 fi
EOF

      FULLPATH="$(pwd)/${WORK_DIR}"

      sudo sh -c "(cd $UAVCORE_FILESYSTEM_DIR && sudo patch -p0 < ${FULLPATH}/startserialtty.patch)"
      sudo rm -rf "${WORK_DIR}/startserialtty.patch"
      # sudo sh -c "rm -rf ${FULLPATH}/startserialtty.patch"      

    else
      echo " - ${UAVCORE_FILESYSTEM_DIR}/usr/sbin/startserialtty) already supports Raspberry Pi Zero W - no patch needed"
    fi
    echo ""
}


check_dependencies
cleanup
prepare_dirs
check_release
make_image
test_package_urls
get_packages
make_onboot_list
make_mydata
extract_filesystem
patch_startserialtty
rebuild_filesystem
cleanup

