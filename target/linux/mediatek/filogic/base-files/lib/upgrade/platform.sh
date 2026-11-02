REQUIRE_IMAGE_METADATA=1
RAMFS_COPY_BIN='fitblk fit_check_sign'

asus_initial_setup()
{
	# initialize UBI if it's running on initramfs
	[ "$(rootfs_type)" = "tmpfs" ] || return 0

	ubirmvol /dev/ubi0 -N rootfs
	ubirmvol /dev/ubi0 -N rootfs_data
	ubirmvol /dev/ubi0 -N jffs2
	ubimkvol /dev/ubi0 -N jffs2 -s 0x3e000
}

buffalo_initial_setup()
{
	local mtdnum="$( find_mtd_index ubi )"
	if [ ! "$mtdnum" ]; then
		echo "unable to find mtd partition ubi"
		return 1
	fi

	ubidetach -m "$mtdnum"
	ubiformat /dev/mtd$mtdnum -y
}

jiorouter_initial_setup()
{
	[ "$(rootfs_type)" = "tmpfs" ] || return 0

	local mtdnum="$( find_mtd_index ubi )"
	if [ ! "$mtdnum" ]; then
		echo "unable to find mtd partition ubi"
		return 1
	fi

	ubidetach -m "$mtdnum" 2>/dev/null
	ubiformat /dev/mtd$mtdnum -y || exit 1
	ubiattach -m "$mtdnum" || exit 1

	local ubidev="$(nand_find_ubi ubi)"
	[ -n "$ubidev" ] || { echo "cannot attach ubi"; exit 1; }

	if ! ubimkvol /dev/$ubidev -n 0 -N u-boot-env -s 0x80000; then
		echo "failed to create u-boot-env volume - aborting"
		exit 1
	fi

	local envdev="$(nand_find_volume "$ubidev" u-boot-env)"
	[ -n "$envdev" ] || { echo "cannot find u-boot-env volume - aborting"; exit 1; }
	echo "/dev/$envdev 0x0 0x80000 0x1f000 5" > /etc/fw_env.config

	# Set boot arguments in freshly created U-Boot environment
	fw_setenv bootcmd 'ubi read 46000000 kernel;fdt addr $(fdtcontroladdr);fdt rm /signature;bootm 0x46000000'
	fw_setenv bootdelay 0
	fw_setenv ipaddr ''
}

xiaomi_initial_setup()
{
	# initialize UBI and setup uboot-env if it's running on initramfs
	[ "$(rootfs_type)" = "tmpfs" ] || return 0

	local mtdnum="$( find_mtd_index ubi )"
	if [ ! "$mtdnum" ]; then
		echo "unable to find mtd partition ubi"
		return 1
	fi

	local kern_mtdnum="$( find_mtd_index ubi_kernel )"
	if [ ! "$kern_mtdnum" ]; then
		echo "unable to find mtd partition ubi_kernel"
		return 1
	fi

	ubidetach -m "$mtdnum"
	ubiformat /dev/mtd$mtdnum -y

	ubidetach -m "$kern_mtdnum"
	ubiformat /dev/mtd$kern_mtdnum -y

	if ! fw_printenv -n flag_try_sys2_failed &>/dev/null; then
		echo "failed to access u-boot-env. skip env setup."
		return 0
	fi

	fw_setenv -s - <<-EOF
		boot_wait on
		uart_en 1
		flag_boot_rootfs 0
		flag_last_success 1
		flag_boot_success 1
		flag_try_sys1_failed 8
		flag_try_sys2_failed 8
	EOF

	local board=$(board_name)
	case "$board" in
	xiaomi,mi-router-ax3000t|\
	xiaomi,mi-router-wr30u-stock)
		fw_setenv mtdparts "nmbm0:1024k(bl2),256k(Nvram),256k(Bdata),2048k(factory),2048k(fip),256k(crash),256k(crash_log),34816k(ubi),34816k(ubi1),32768k(overlay),12288k(data),256k(KF)"
		;;
	xiaomi,redmi-router-ax6000-stock)
		fw_setenv mtdparts "nmbm0:1024k(bl2),256k(Nvram),256k(Bdata),2048k(factory),2048k(fip),256k(crash),256k(crash_log),30720k(ubi),30720k(ubi1),51200k(overlay)"
		;;
	esac
}

clx_s20p_emmc_do_upgrade() {
	local image="$1"
	local tmpdir sysdev partname part_count
	local kern_dev root_dev kern_size root_size
	local kern_bytes root_bytes kern_blocks root_blocks
	local kern_capacity root_capacity squashfs_words squashfs_bytes

	tmpdir="$(mktemp -d)" || return 1

	# Extract both image members before touching eMMC.
	tar -xOf "$image" sysupgrade-clx_s20p/kernel > "$tmpdir/kernel" 2>/dev/null || {
		echo "S20P: cannot extract kernel."
		rm -rf "$tmpdir"
		return 1
	}

	tar -xOf "$image" sysupgrade-clx_s20p/root > "$tmpdir/root" 2>/dev/null || {
		echo "S20P: cannot extract rootfs."
		rm -rf "$tmpdir"
		return 1
	}

	fit_check_image "$tmpdir/kernel" || {
		echo "S20P: invalid FIT kernel."
		rm -rf "$tmpdir"
		return 1
	}

	[ "$(dd if="$tmpdir/root" bs=4 count=1 2>/dev/null)" = "hsqs" ] || {
		echo "S20P: invalid SquashFS rootfs."
		rm -rf "$tmpdir"
		return 1
	}

	# Locate unique kernel and rootfs partitions on mmcblk0.
	part_count=0
	for sysdev in /sys/class/block/mmcblk0p[0-9]*; do
		[ -r "$sysdev/uevent" ] || continue
		partname="$(sed -n 's/^PARTNAME=//p' "$sysdev/uevent")"

		case "$partname" in
			kernel)
				part_count=$((part_count + 1))
				kern_dev="/dev/$(basename "$sysdev")"
				;;
			rootfs)
				part_count=$((part_count + 1))
				root_dev="/dev/$(basename "$sysdev")"
				;;
		esac
	done

	[ "$part_count" -eq 2 ] &&
	[ "$kern_dev" = "/dev/mmcblk0p4" ] &&
	[ "$root_dev" = "/dev/mmcblk0p5" ] || {
		echo "S20P: expected unique kernel p4 and rootfs p5 partitions."
		rm -rf "$tmpdir"
		return 1
	}

	[ -b "$kern_dev" ] && [ -b "$root_dev" ] || {
		echo "S20P: eMMC partition device is missing."
		rm -rf "$tmpdir"
		return 1
	}

	kern_capacity="$(cat /sys/class/block/mmcblk0p4/size)" || {
		rm -rf "$tmpdir"
		return 1
	}
	root_capacity="$(cat /sys/class/block/mmcblk0p5/size)" || {
		rm -rf "$tmpdir"
		return 1
	}

	case "$kern_capacity:$root_capacity" in
		*[!0-9:]*|:*|*:)
			echo "S20P: invalid partition size."
			rm -rf "$tmpdir"
			return 1
			;;
	esac

	kern_bytes="$(wc -c < "$tmpdir/kernel")"
	root_bytes="$(wc -c < "$tmpdir/root")"

	[ "$kern_bytes" -gt 0 ] &&
	[ "$root_bytes" -gt 0 ] &&
	[ $((root_bytes % 512)) -eq 0 ] || {
		echo "S20P: invalid image size or unaligned rootfs."
		rm -rf "$tmpdir"
		return 1
	}

	kern_blocks=$(((kern_bytes + 511) / 512))

	# Read SquashFS bytes_used (64-bit little-endian at offset 40).
	squashfs_words="$(hexdump -v -s 40 -n 8 -e '1/4 "%u\n"' "$tmpdir/root")" || {
		echo "S20P: cannot read SquashFS superblock."
		rm -rf "$tmpdir"
		return 1
	}
	set -- $squashfs_words
	[ "$#" -eq 2 ] || {
		echo "S20P: invalid SquashFS bytes_used field."
		rm -rf "$tmpdir"
		return 1
	}
	case "$1:$2" in
		*[!0-9:]*|:*|*:)
			echo "S20P: invalid SquashFS bytes_used value."
			rm -rf "$tmpdir"
			return 1
			;;
	esac
	squashfs_bytes=$(($1 + ($2 * 4294967296)))
	[ "$squashfs_bytes" -gt 0 ] && [ "$squashfs_bytes" -le "$root_bytes" ] || {
		echo "S20P: invalid SquashFS filesystem size."
		rm -rf "$tmpdir"
		return 1
	}

	# fstools aligns the overlay start to 64 KiB (128 sectors).
	root_blocks=$(((squashfs_bytes + 65535) / 65536 * 128))

	[ "$kern_blocks" -le "$kern_capacity" ] &&
	[ $((root_blocks + 8)) -le "$root_capacity" ] || {
		echo "S20P: image exceeds partition capacity."
		rm -rf "$tmpdir"
		return 1
	}

	echo "S20P: invalidating old kernel..."
	dd if=/dev/zero of="$kern_dev" bs=512 count=8 || {
		echo "S20P: cannot invalidate old kernel."
		rm -rf "$tmpdir"
		return 1
	}
	sync || {
		rm -rf "$tmpdir"
		return 1
	}

	echo "S20P: writing rootfs..."
	dd if="$tmpdir/root" of="$root_dev" bs=512 || {
		echo "S20P: rootfs write failed."
		rm -rf "$tmpdir"
		return 1
	}
	sync || {
		rm -rf "$tmpdir"
		return 1
	}

	dd if="$root_dev" of="$tmpdir/root.readback" bs=512 count="$((root_bytes / 512))" || {
		echo "S20P: rootfs readback failed."
		rm -rf "$tmpdir"
		return 1
	}
	cmp -s "$tmpdir/root" "$tmpdir/root.readback" || {
		echo "S20P: rootfs verification failed."
		rm -rf "$tmpdir"
		return 1
	}

	# Invalidate any stale overlay filesystem at the aligned offset.
	dd if=/dev/zero of="$root_dev" bs=512 seek="$root_blocks" count=8 || {
		echo "S20P: cannot invalidate old overlay."
		rm -rf "$tmpdir"
		return 1
	}
	sync || {
		rm -rf "$tmpdir"
		return 1
	}

	echo "S20P: writing kernel..."
	dd if="$tmpdir/kernel" of="$kern_dev" bs=512 || {
		echo "S20P: kernel write failed."
		rm -rf "$tmpdir"
		return 1
	}
	sync || {
		rm -rf "$tmpdir"
		return 1
	}

	dd if="$kern_dev" of="$tmpdir/kernel.readback.raw" bs=512 count="$kern_blocks" || {
		echo "S20P: kernel readback failed."
		rm -rf "$tmpdir"
		return 1
	}
	head -c "$kern_bytes" "$tmpdir/kernel.readback.raw" > "$tmpdir/kernel.readback" || {
		rm -rf "$tmpdir"
		return 1
	}
	cmp -s "$tmpdir/kernel" "$tmpdir/kernel.readback" || {
		echo "S20P: kernel verification failed."
		rm -rf "$tmpdir"
		return 1
	}

	# Used by emmc_copy_config() to restore backup after rootfs.
	export EMMC_ROOT_DEV="$root_dev"
	export EMMC_ROOTFS_BLOCKS="$root_blocks"

	rm -rf "$tmpdir"
	echo "S20P: eMMC upgrade and readback verification successful."
	return 0
}

platform_do_upgrade() {
	local board=$(board_name)

	case "$board" in
	abt,asr3000|\
	acer,predator-w6x-ubootmod|\
	asus,zenwifi-bt8-ubootmod|\
	bananapi,bpi-r3|\
	bananapi,bpi-r3-mini|\
	bananapi,bpi-r4|\
	bananapi,bpi-r4-2g5|\
	bananapi,bpi-r4-poe|\
	bananapi,bpi-r4-lite|\
	bazis,ax3000wm|\
	cmcc,a10-ubootmod|\
	cmcc,rax3000m|\
	comfast,cf-wr632ax-ubootmod|\
	creatlentem,clt-r30b1-ubi|\
	cudy,m3000-v1-ubootmod|\
	cudy,m3000-v2-yt8821-ubootmod|\
	cudy,tr3000-v1-ubootmod|\
	cudy,wbr3000uax-v1-ubootmod|\
	cudy,wr3000e-v1-ubootmod|\
	cudy,wr3000s-v1-ubootmod|\
	cudy,wr3000h-v1-ubootmod|\
	cudy,wr3000p-v1-ubootmod|\
	gatonetworks,gdsp|\
	globitel,bt-r320|\
	h3c,magic-nx30-pro|\
	imou,hx21|\
	jcg,q30-pro|\
	jdcloud,re-cp-03|\
	konka,komi-a31|\
	mediatek,mt7981-rfb|\
	mediatek,mt7988a-rfb|\
	mercusys,mr90x-v1-ubi|\
	netis,eap930-v1|\
	netis,n6-v2|\
	netis,nx30v2|\
	netis,nx31|\
	netis,nx32u|\
	nokia,ea0326gmp|\
	openwrt,one|\
	netcore,n60|\
	netcore,n60-pro|\
	qihoo,360t7|\
	qihoo,360t7-ubi|\
	routerich,ax3000-ubootmod|\
	routerich,be7200|\
	snr,snr-cpe-ax2|\
	teralink,tl3020-256mb|\
	tplink,tl-xdr4288|\
	tplink,tl-xdr6086|\
	tplink,tl-xdr6088|\
	tplink,tl-xtr8488|\
	wavlink,wl-wnt100x3-ubootmod|\
	xiaomi,mi-router-ax3000t-ubootmod|\
	xiaomi,redmi-router-ax6000-ubootmod|\
	xiaomi,mi-router-wr30u-ubootmod|\
	zyxel,ex5601-t0-ubootmod|\
	zyxel,wx5600-t0-ubootmod)
		fit_do_upgrade "$1"
		;;
	clx,s20p)
		unset CI_DATAPART EMMC_DATA_DEV
		clx_s20p_emmc_do_upgrade "$1"
		;;
	acer,predator-w6|\
	acer,predator-w6d|\
	acer,vero-w6m|\
	airpi,ap3000m|\
	arcadyan,mozart|\
	glinet,gl-mt2500|\
	glinet,gl-mt2500-airoha|\
	glinet,gl-mt6000|\
	glinet,gl-x3000|\
	glinet,gl-xe3000|\
	hiveton,h5000m|\
	huasifei,wh3000|\
	huasifei,wh3000-pro-emmc|\
	smartrg,sdg-8612|\
	smartrg,sdg-8614|\
	smartrg,sdg-8622|\
	smartrg,sdg-8632|\
	smartrg,sdg-8733|\
	smartrg,sdg-8733a|\
	smartrg,sdg-8734)
		CI_KERNPART="kernel"
		CI_ROOTPART="rootfs"
		emmc_do_upgrade "$1"
		;;
	airtel,aap4221zy)
		# ZyXEL zloader requires a "zyfwinfo" UBI volume with valid
		# metadata (magic + checksum) to select the boot partition.
		# Without it, zloader refuses to boot the firmware. It has to be
		# written before nand_do_upgrade(), which sizes rootfs_data to
		# fill the remaining space.
		local ubidev="$(nand_attach_ubi "${CI_UBIPART:-ubi}")"
		[ "$ubidev" ] || nand_do_upgrade_failed
		local vol="$(nand_find_volume "$ubidev" zyfwinfo)"
		if [ ! "$vol" ]; then
			# rootfs_data may occupy all LEBs, nand_do_upgrade() recreates it
			[ "$(nand_find_volume "$ubidev" rootfs_data)" ] && \
				ubirmvol /dev/$ubidev -N rootfs_data
			if ! ubimkvol /dev/$ubidev -N zyfwinfo -s 256 -t dynamic; then
				echo "cannot create zyfwinfo volume"
				nand_do_upgrade_failed
			fi
			vol="$(nand_find_volume "$ubidev" zyfwinfo)"
		fi
		local tmpfile="/tmp/zyfwinfo.bin"
		echo -n -e '\x45\x58\x59\x5A\x02\x00\xB3\x15\x00\x01\x00\x00' > "$tmpfile"
		dd if=/dev/zero bs=1 count=242 >> "$tmpfile" 2>/dev/null
		echo -n -e '\x1B\x02' >> "$tmpfile"
		ubiupdatevol /dev/$vol -s 256 "$tmpfile"
		rm -f "$tmpfile"
		nand_do_upgrade "$1"
		;;
	asus,rt-ax52|\
	asus,rt-ax57m|\
	asus,rt-ax59u|\
	asus,tuf-ax4200|\
	asus,tuf-ax4200q|\
	asus,tuf-ax6000|\
	asus,zenwifi-bt8)
		CI_UBIPART="UBI_DEV"
		CI_KERNPART="linux"
		nand_do_upgrade "$1"
		;;
	buffalo,wsr-6000ax8|\
	cudy,wr3000h-v1|\
	cudy,wr3000p-v1|\
	huasifei,wh3000-pro-nand|\
	huasifei,wh3000r-nand|\
	jiorouter,ax6000-jidu6101|\
	jiorouter,ax6000-jidu6j01)
		CI_UBIPART="ubi"
		nand_do_upgrade "$1"
		;;
	cudy,re3000-v1|\
	cudy,wr3000-v1|\
	kebidumei,ax3000-u22|\
	totolink,x6000r|\
	wavlink,wl-wn573hx3|\
	widelantech,wap430x|\
	yuncore,ax835)
		default_do_upgrade "$1"
		;;
	dlink,aquila-pro-ai-e30-a1|\
	dlink,aquila-pro-ai-m30-a1|\
	dlink,aquila-pro-ai-m60-a1)
		fw_setenv sw_tryactive 0
		nand_do_upgrade "$1"
		;;
	elecom,wrc-x3000gs3)
		local bootnum="$(mstc_rw_bootnum)"
		case "$bootnum" in
		1|2)
			CI_UBIPART="ubi$bootnum"
			[ -z "$(find_mtd_index $CI_UBIPART)" ] &&
				CI_UBIPART="ubi"
			;;
		*)
			v "invalid bootnum found ($bootnum), rebooting..."
			nand_do_upgrade_failed
			;;
		esac
		nand_do_upgrade "$1"
		;;
	mercusys,mr80x-v3|\
	mercusys,mr85x|\
	mercusys,mr90x-v1|\
	tplink,archer-ax80-v1|\
	tplink,archer-ax80-v1-eu|\
	tplink,be450|\
	tplink,re6000xd)
		CI_UBIPART="ubi0"
		nand_do_upgrade "$1"
		;;
	netgear,eax17)
		echo "UPGRADING SECOND SLOT"
		CI_KERNPART="kernel2"
		CI_ROOTPART="rootfs2"
		nand_do_flash_file "$1" || nand_do_upgrade_failed
		echo "UPGRADING PRIMARY SLOT"
		CI_KERNPART="kernel"
		CI_ROOTPART="rootfs"
		nand_do_flash_file "$1" || nand_do_upgrade_failed
		nand_do_upgrade_success
		;;
	tplink,fr365-v1)
		CI_UBIPART="ubi"
		CI_KERNPART="kernel"
		CI_ROOTPART="rootfs"
		nand_do_upgrade "$1"
		;;
	teltonika,rutc50)
		CI_UBIPART="$(cmdline_get_var ubi.mtd)"
		nand_do_upgrade "$1"
		;;
	nradio,c8-668gl)
		CI_DATAPART="rootfs_data"
		CI_KERNPART="kernel_2nd"
		CI_ROOTPART="rootfs_2nd"
		emmc_do_upgrade "$1"
		;;
	ubnt,unifi-6-plus)
		CI_KERNPART="kernel0"
		EMMC_ROOT_DEV="$(cmdline_get_var root)"
		emmc_do_upgrade "$1"
		;;
	unielec,u7981-01*)
		local rootdev="$(cmdline_get_var root)"
		rootdev="${rootdev##*/}"
		rootdev="${rootdev%p[0-9]*}"
		case "$rootdev" in
		mmc*)
			CI_ROOTDEV="$rootdev"
			CI_KERNPART="kernel"
			CI_ROOTPART="rootfs"
			emmc_do_upgrade "$1"
			;;
		*)
			CI_KERNPART="fit"
			nand_do_upgrade "$1"
			;;
		esac
		;;
	xiaomi,mi-router-ax3000t|\
	xiaomi,mi-router-wr30u-stock|\
	xiaomi,redmi-router-ax6000-stock)
		CI_KERN_UBIPART=ubi_kernel
		CI_ROOT_UBIPART=ubi
		CI_DATA_UBIPART=ubi
		nand_do_upgrade "$1"
		;;
	*)
		nand_do_upgrade "$1"
		;;
	esac
}

PART_NAME=firmware

clx_s20p_check_image() {
	local tmpdir members expected magic

	tmpdir="$(mktemp -d)" || return 74

	members="$(tar -tf "$1" 2>/dev/null)" || {
		rm -rf "$tmpdir"
		return 74
	}

	expected="$(printf '%s\n' \
		'sysupgrade-clx_s20p/' \
		'sysupgrade-clx_s20p/CONTROL' \
		'sysupgrade-clx_s20p/kernel' \
		'sysupgrade-clx_s20p/root')"

	[ "$members" = "$expected" ] || {
		echo "Invalid S20P image members."
		rm -rf "$tmpdir"
		return 74
	}

	[ "$(tar -xOf "$1" sysupgrade-clx_s20p/CONTROL 2>/dev/null)" = "BOARD=clx_s20p" ] || {
		echo "Invalid S20P image board."
		rm -rf "$tmpdir"
		return 74
	}

	tar -xOf "$1" sysupgrade-clx_s20p/kernel > "$tmpdir/kernel" 2>/dev/null &&
	tar -xOf "$1" sysupgrade-clx_s20p/root > "$tmpdir/root" 2>/dev/null || {
		echo "Cannot extract S20P image."
		rm -rf "$tmpdir"
		return 74
	}

	fit_check_image "$tmpdir/kernel" || {
		rm -rf "$tmpdir"
		return 74
	}

	magic="$(dd if="$tmpdir/root" bs=4 count=1 2>/dev/null)"
	[ "$magic" = "hsqs" ] || {
		echo "Invalid S20P root filesystem."
		rm -rf "$tmpdir"
		return 74
	}

	rm -rf "$tmpdir"
	return 0
}

platform_check_image() {
	local board=$(board_name)

	[ "$#" -gt 1 ] && return 1

	case "$board" in
	clx,s20p)
		clx_s20p_check_image "$1"
		return $?
		;;
	abt,asr3000|\
	acer,predator-w6x-ubootmod|\
	asus,zenwifi-bt8-ubootmod|\
	bananapi,bpi-r3|\
	bananapi,bpi-r3-mini|\
	bananapi,bpi-r4|\
	bananapi,bpi-r4-2g5|\
	bananapi,bpi-r4-poe|\
	bananapi,bpi-r4-lite|\
	bazis,ax3000wm|\
	cmcc,a10-ubootmod|\
	cmcc,rax3000m|\
	comfast,cf-wr632ax-ubootmod|\
	creatlentem,clt-r30b1-ubi|\
	cudy,m3000-v1-ubootmod|\
	cudy,m3000-v2-yt8821-ubootmod|\
	cudy,tr3000-v1-ubootmod|\
	cudy,wbr3000uax-v1-ubootmod|\
	cudy,wr3000e-v1-ubootmod|\
	cudy,wr3000s-v1-ubootmod|\
	cudy,wr3000h-v1-ubootmod|\
	cudy,wr3000p-v1-ubootmod|\
	gatonetworks,gdsp|\
	globitel,bt-r320|\
	h3c,magic-nx30-pro|\
	jcg,q30-pro|\
	jdcloud,re-cp-03|\
	konka,komi-a31|\
	mediatek,mt7981-rfb|\
	mediatek,mt7988a-rfb|\
	mercusys,mr90x-v1-ubi|\
	nokia,ea0326gmp|\
	netis,eap930-v1|\
	netis,n6-v2|\
	netis,nx32u|\
	openwrt,one|\
	netcore,n60|\
	qihoo,360t7|\
	qihoo,360t7-ubi|\
	routerich,ax3000-ubootmod|\
	teralink,tl3020-256mb|\
	tplink,tl-xdr4288|\
	tplink,tl-xdr6086|\
	tplink,tl-xdr6088|\
	tplink,tl-xtr8488|\
	wavlink,wl-wnt100x3-ubootmod|\
	xiaomi,mi-router-ax3000t-ubootmod|\
	xiaomi,redmi-router-ax6000-ubootmod|\
	xiaomi,mi-router-wr30u-ubootmod|\
	zyxel,ex5601-t0-ubootmod)
		fit_check_image "$1"
		return $?
		;;
	creatlentem,clt-r30b1|\
	creatlentem,clt-r30b1-112m|\
	hiveton,h5000m|\
	nradio,c8-668gl)
		# tar magic `ustar`
		magic="$(dd if="$1" bs=1 skip=257 count=5 2>/dev/null)"

		[ "$magic" != "ustar" ] && {
			echo "Invalid image type."
			return 1
		}

		return 0
		;;
	*)
		nand_do_platform_check "$board" "$1"
		return $?
		;;
	esac

	return 0
}

platform_copy_config() {
	case "$(board_name)" in
	bananapi,bpi-r3|\
	bananapi,bpi-r3-mini|\
	bananapi,bpi-r4|\
	bananapi,bpi-r4-2g5|\
	bananapi,bpi-r4-poe|\
	bananapi,bpi-r4-lite|\
	cmcc,rax3000m|\
	gatonetworks,gdsp|\
	mediatek,mt7988a-rfb)
		if [ "$CI_METHOD" = "emmc" ]; then
			emmc_copy_config
		fi
		;;
	clx,s20p|\
	acer,predator-w6|\
	acer,predator-w6d|\
	acer,vero-w6m|\
	airpi,ap3000m|\
	arcadyan,mozart|\
	glinet,gl-mt2500|\
	glinet,gl-mt2500-airoha|\
	glinet,gl-mt6000|\
	glinet,gl-x3000|\
	glinet,gl-xe3000|\
	globitel,bt-r320|\
	hiveton,h5000m|\
	huasifei,wh3000|\
	huasifei,wh3000-pro-emmc|\
	jdcloud,re-cp-03|\
	nradio,c8-668gl|\
	smartrg,sdg-8612|\
	smartrg,sdg-8614|\
	smartrg,sdg-8622|\
	smartrg,sdg-8632|\
	smartrg,sdg-8733|\
	smartrg,sdg-8733a|\
	smartrg,sdg-8734|\
	ubnt,unifi-6-plus)
		emmc_copy_config
		;;
	esac
}

platform_pre_upgrade() {
	local board=$(board_name)

	case "$board" in
	asus,rt-ax52|\
	asus,rt-ax57m|\
	asus,rt-ax59u|\
	asus,tuf-ax4200|\
	asus,tuf-ax4200q|\
	asus,tuf-ax6000|\
	asus,zenwifi-bt8)
		asus_initial_setup
		;;
	buffalo,wsr-6000ax8)
		buffalo_initial_setup
		;;
	jiorouter,ax6000-jidu6101|\
	jiorouter,ax6000-jidu6j01)
		jiorouter_initial_setup
		;;
	xiaomi,mi-router-ax3000t|\
	xiaomi,mi-router-wr30u-stock|\
	xiaomi,redmi-router-ax6000-stock)
		xiaomi_initial_setup
		;;
	esac
}
