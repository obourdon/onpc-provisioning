#!/bin/bash

# Exit on errors
set -e

# Import some utilities
. $(dirname $0)/functions.sh

CMDDIR=$(dirname $(dirname $($linkcmd -f $0)))

# VM parameters
vmname=${SLAVE_VM_NAME:-"slave"}
vmmem=${SLAVE_VM_MEM:-1024}
vmcpus=${SLAVE_VM_CPUS:-1}
vmdisk=${SLAVE_VM_DISK:-4096}
maxvms=${MAX_SLAVES:-5}
startingvmid=${START:-0}
vmvncbindip=${SLAVE_VM_VNC_IP:-"0.0.0.0"}
vmvncport=${SLAVE_VM_VNC_PORT:-5900}
vbmcport=${SLAVE_VM_VBMC_PORT:-6000}

# Check command line arguments
if [ $# -ne 1 ]; then
	echo -e "\nUsage: $(basename $0) #nb-vms-to-launch\n"
	exit 1
fi

checkstring SLAVE_VM_NAME   "$vmname"      false
checkstring SLAVE_VM_VNC_IP "$vmvncbindip" false '^([0–9]{1,3}\.){3}([0–9]{1,3})$'

checknumber '#nb-vms-to-launch' $1         1    $maxvms
checknumber SLAVE_VM_MEM        $vmmem     1024 ""      8
checknumber SLAVE_VM_DISK       $vmdisk    4096 ""      1024
checknumber SLAVE_VM_CPUS       $vmcpus    1    16      1
checknumber SLAVE_VM_VNC_PORT   $vmvncport 5900 ""      1

# Launch VM(s) according to provider
for i in $(seq 1 $1); do
	idx=$(($startingvmid + $i))
	lvmname=${vmname}-$idx
	if [ "$virtprovider" == "vbox" ]; then
		# Check if VM already exists
		if $vboxcmd list vms | egrep -q "^\"${lvmname}\" "; then
			yesorno "VirtualBox VM with name [$lvmname] already exists" "Do you want to erase it [y/n] "
			if $vboxcmd controlvm $lvmname poweroff 2>/dev/null; then
				echo "$lvmname was powered off successfully"
				# Wait a bit for poweroff to occur
				sleep 2
			else
				echo "$lvmname was already powered off"
			fi
			$vboxcmd unregistervm $lvmname --delete
		fi

		# Base of VM is Ubuntu 64bits
		vmuuid=$($vboxcmd createvm --name $lvmname --ostype Ubuntu_64 --register | egrep "^UUID: " | awk '{print $NF}')
		echo "Created $lvmname: $vmuuid"
		# VM basics
		$vboxcmd modifyvm $lvmname --memory $vmmem --cpus $vmcpus --boot1 net --boot2 disk --boot3 none --audio none --usb off --rtcuseutc on --vram 16 --pae off
		# VM networks
		$vboxcmd modifyvm $lvmname --nic1 intnet
		# VM HDD
		$vboxcmd storagectl $lvmname --name SATA --add sata --controller IntelAHCI --portcount 1 --hostiocache off
		eval $($vboxcmd showvminfo $lvmname --machinereadable | grep ^CfgFile=)
		vmdir=$(dirname "$CfgFile")
		vmdiskuuid=$($vboxcmd createmedium disk --filename "$vmdir"/$lvmname --size $vmdisk | egrep "^.* UUID: " | awk '{print $NF}')
		$vboxcmd storageattach $lvmname --storagectl SATA --type hdd --port 0 --device 0 --medium "$vmdir"/$lvmname.vdi
		# Start VM
		$vboxcmd startvm $lvmname --type headless
	elif [ "$virtprovider" == "kvm" ]; then
		# Check if VM already exists
		if $virshcmd list --all --name 2>/dev/null | egrep -q "^${lvmname}$"; then
			yesorno "KVM VM with name [$lvmname] already exists" "Do you want to erase it [y/n] "
			if $virshcmd destroy $lvmname 2>/dev/null; then
				echo "$lvmname was powered off successfully"
				# Wait a bit for poweroff to occur
				sleep 2
			else
				echo "$lvmname was already powered off"
			fi
			if vbmc stop $lvmname 2>/dev/null; then
				echo "vbmc stop $lvmname OK"
			else
				echo "vbmc stop $lvmname KO"
			fi
			if vbmc delete $lvmname 2>/dev/null; then
				echo "vbmc delete $lvmname OK"
			else
				echo "vbmc delete $lvmname KO"
			fi
			$virshcmd undefine $lvmname --snapshots-metadata --remove-all-storage
		fi
		# As VNC is much more performant than virt-viewer, unsetting DISPLAY
		# will prevent from launching the latest unless FORCEX environment
		# variable is set
		if [ -z "$FORCEX" ]; then
			unset DISPLAY
		fi
		lvmvncport=$(($vmvncport + $idx))
		echo -e "\nYou can attach to VNC console at ${vmvncbindip}:$lvmvncport (local IP address is $localip)\n"
		# Start VM
		$virtinstallcmd -v --virt-type kvm --name $lvmname --ram $vmmem --vcpus $vmcpus --os-type linux --os-variant ubuntu16.04 \
			--disk path=/var/lib/libvirt/images/$lvmname.qcow2,size=$(($vmdisk / 1024)),bus=virtio,format=qcow2 \
			--network bridge=virbr1,model=virtio --pxe --boot network,hd --noautoconsole \
			--graphics vnc,listen=$vmvncbindip,port=$lvmvncport
		sleep 2
		macaddr=$($virshcmd dumpxml $lvmname | xmllint --xpath 'string(//interface[@type="bridge"]/mac/@address)' -)
		uuid=$($virshcmd dumpxml $lvmname | xmllint --xpath 'string(//uuid)' -)
		nuuid=$(python -c "import sys;import uuid;print str(uuid.uuid3(uuid.NAMESPACE_DNS,sys.argv[1]))" $lvmname)
		lvbmcport=$(($vbmcport + $idx))
		vbmc add $lvmname --port $lvbmcport
		vbmc start $lvmname
		echo "$lvmname MAC=$macaddr UUID=$uuid BMCport=$lvbmcport"
	fi
done

exit 0
