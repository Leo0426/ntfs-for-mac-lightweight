"""Pure checks for the explicitly pinned sacrificial USB experiment, not Gate evidence."""
import re


class TargetError(Exception):
    pass


def require(condition, reason):
    if not condition:
        raise TargetError(reason)


def check_target(expected, whole, volume, parts):
    disk = whole.get('DeviceIdentifier')
    device = volume.get('DeviceIdentifier')
    require(isinstance(disk, str) and re.fullmatch(r'disk[0-9]+', disk), 'invalidWholeDisk')
    require(isinstance(device, str) and re.fullmatch(re.escape(disk) + r's[0-9]+', device),
            'invalidPartitionDevice')
    require(whole.get('WholeDisk') is True and whole.get('Internal') is False
            and whole.get('Removable') is True and whole.get('Ejectable') is True
            and whole.get('WritableMedia') is True and whole.get('BusProtocol') == 'USB'
            and whole.get('MediaName') == expected['mediaName']
            and type(whole.get('Size')) is int and whole['Size'] == expected['physicalBytes'],
            'physicalTargetMismatch')
    require(volume.get('WholeDisk') is False and volume.get('Internal') is False
            and volume.get('WritableMedia') is True and volume.get('ParentWholeDisk') == disk
            and volume.get('DeviceNode') == '/dev/' + device
            and volume.get('DiskUUID') == expected['partitionUUID']
            and type(volume.get('Size')) is int and volume['Size'] == expected['partitionBytes'],
            'partitionTargetMismatch')
    require(len(parts) == 2 and all(isinstance(p, dict) for p in parts), 'siblingCountMismatch')
    data = [p for p in parts if p.get('DeviceIdentifier') == device]
    efi = [p for p in parts if p.get('DeviceIdentifier') != device]
    require(len(data) == len(efi) == 1, 'ambiguousSiblings')
    require(data[0].get('DiskUUID') == expected['partitionUUID']
            and data[0].get('Content') == 'Microsoft Basic Data'
            and data[0].get('Size') == expected['partitionBytes']
            and data[0].get('MountPoint', '') == volume.get('MountPoint', ''), 'topologyMismatch')
    require(efi[0].get('DiskUUID') == expected['efiUUID'] and efi[0].get('Content') == 'EFI'
            and efi[0].get('Size') == 209715200
            and isinstance(efi[0].get('DeviceIdentifier'), str)
            and re.fullmatch(re.escape(disk) + r's[0-9]+', efi[0]['DeviceIdentifier'])
            and efi[0].get('MountPoint', '') == '', 'siblingMismatchOrMounted')
    return disk, '/dev/' + device


def check_writable_mount(lines, device, root):
    matches = [line for line in lines if ' on ' + root + ' ' in line]
    require(len(matches) == 1, 'mountMissingOrAmbiguous')
    line = matches[0]
    prefix = device + ' on ' + root + ' (macfuse, '
    require(line.startswith(prefix) and line.endswith(')'), 'mountSourceOrBackendMismatch')
    flags = set(line[len(prefix):-1].split(', '))
    require({'local', 'fskit', 'nodev', 'nosuid'} <= flags and 'read-only' not in flags,
            'mountNotVerifiedWritableFSKit')
    return line
