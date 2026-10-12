#!/usr/bin/env python3
"""Reproducible, read-only Mach-O inventory of an authorized decrypted IPA.

No third-party dependencies. Offsets are hexadecimal, relative to the Mach-O
slice (not the ZIP or fat file); every slice and file has a SHA-256 identity.
Selector-reference tables mean references, not observed invocation. Method-name
strings do NOT establish references or callers. Module prefixes establish static
presence, not SDK ownership of a particular API call. Runtime lookup, JIT/web
content, server-selected behavior and first-run writes require separate evidence.

Usage: python3 tools/enumerate_leak_binary.py FILE.ipa -o inventory.json
       python3 tools/enumerate_leak_binary.py --self-test
"""
import argparse
import collections
import gzip
import hashlib
import json
import os
import plistlib
import re
import struct
import sys
import urllib.parse
import zipfile


class InvalidBinary(ValueError):
    pass


def sha(data):
    return hashlib.sha256(data).hexdigest()


def checked(data, offset, size):
    if offset < 0 or size < 0 or offset > len(data) or size > len(data) - offset:
        raise InvalidBinary(f"out-of-bounds offset={offset} size={size} file={len(data)}")
    return memoryview(data)[offset:offset + size]


def unpack(data, fmt, offset):
    return struct.unpack(fmt, checked(data, offset, struct.calcsize(fmt)))


def cstr(data, offset, end=None):
    end = len(data) if end is None else end
    checked(data, offset, end - offset)
    stop = data.find(b"\0", offset, min(end, offset + 65536))
    if stop < 0:
        raise InvalidBinary(f"unterminated string at {offset}")
    return data[offset:stop].decode("utf-8", "replace")


def strings(data, section):
    start, size = section["offset"], section["size"]
    raw = bytes(checked(data, start, size))
    pos = 0
    for value in raw.split(b"\0"):
        if value:
            yield start + pos, value.decode("utf-8", "replace")
        pos += len(value) + 1


def swift_module(name):
    # Swift ABI length-prefixed outer module for common manglings. We retain all
    # unmatched symbols elsewhere; absence from this heuristic is not absence.
    match = re.match(r"_?(?:\$s|\$S|_Tt[CVOP])([0-9]{1,3})(.*)", name)
    if match:
        length = int(match.group(1))
        rest = match.group(2)
        if 0 < length <= len(rest) and re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", rest[:length]):
            return rest[:length]
    return None


API_PATTERNS = {
    "identifiers": r"identifierForVendor|advertisingIdentifier|advertisingTrackingEnabled|trackingAuthorizationStatus|ASIdentifierManager|ATTrackingManager|MGCopy|MGGet|uniqueIdentifier|uniqueDeviceIdentifier|deviceIdentifier|deviceID|installID|installationID|installationId|identifierWithCompletion",
    "preferences": r"NSUserDefaults|CFPreferences|standardUserDefaults|initWithSuiteName|persistentDomainForName|setPersistentDomain|suiteName|synchronize|ubiquitousKeyValue|NSUbiquitousKeyValueStore",
    "keychain": r"SecItem|kSecAttrAccessGroup|kSecAttrSynchronizable|keychain|Keychain|accessGroup|kSecClass",
    "pasteboard": r"UIPasteboard|pasteboard|Pasteboard|setItems:|hasURLs|hasStrings|detectPatterns|itemProviders",
    "cookies_cache": r"HTTPCookie|CookieStorage|URLCache|cachedResponseForRequest|websiteDataStore|WKWebsiteDataStore|fetchDataRecordsOfTypes|removeDataOfTypes",
    "network_session": r"NSURLSession|URLSession|URLSessionConfiguration|backgroundSessionConfiguration|ephemeralSessionConfiguration|dataTaskWith|uploadTaskWith|downloadTaskWith|webSocketTaskWith|NSURLConnection|HTTPAdditionalHeaders|connectionProxyDictionary",
    "network_low_level": r"^_(?:socket|connect|connectx|send|sendto|sendmsg|recv|recvfrom|recvmsg|getaddrinfo|getnameinfo|res_[A-Za-z_]+|dnssd_[A-Za-z_]+|DNSService[A-Za-z_]+|nw_[A-Za-z_]+|CFStream[A-Za-z_]+|CFSocket[A-Za-z_]+)$|NetworkExtension|NEAppProxy|NEPacketTunnel",
    "web_auth": r"WKWebView|WKNavigation|loadRequest:|loadHTMLString|SFSafariViewController|ASWebAuthenticationSession|SFAuthenticationSession|openURL|canOpenURL|WKHTTPCookieStore",
    "cloud_groups_files": r"CloudKit|CKContainer|CKDatabase|ubiquity|ubiquitous|containerURLForSecurityApplicationGroupIdentifier|NSFileManager|NSHomeDirectory|NSTemporaryDirectory|NSSearchPathForDirectoriesInDomains|FileHandle|FileCoordinator|FilePresenter|applicationGroups",
    "mach_notifications": r"^_(?:mach_[A-Za-z_]+|bootstrap_[A-Za-z_]+|notify_[A-Za-z_]+)$|DarwinNotifyCenter|CFNotificationCenter|NSDistributedNotification|NSNotificationCenter",
    "device_fingerprint": r"UIDevice|UIScreen|NSLocale|NSTimeZone|NSProcessInfo|currentDevice|systemVersion|systemName|model$|localizedModel|batteryLevel|batteryState|batteryMonitoring|identifierForVendor|physicalMemory|processorCount|operatingSystemVersion|systemUptime|lowPowerMode|thermalState|activeProcessorCount|userAgent|_sysctl|_uname|IORegistry|IOService|IOPS|IOPM|CMMotion|CMDeviceMotion|CMPedometer|CMAttitude|CLLocation|accelerometer|gyroscope|magnetometer",
    "launch_dynamic": r"^_(?:getenv|environ|dlopen|dlsym|objc_getClass|objc_lookUpClass|sel_registerName|NSClassFromString|NSSelectorFromString)$|environment$|processArguments|arguments$|performSelector|valueForKey|respondsToSelector",
}
COMPILED_APIS = {key: re.compile(pattern, re.I if key in ("identifiers", "keychain") else 0)
                 for key, pattern in API_PATTERNS.items()}
KEY_PATTERN = re.compile(r"(?:^(?:gLoid|analytics[-_]|AppsFlyer|AppSessionId|firebase[-_])|(?:[._-](?:device|install|installation|session|vendor|advertising|anonymous|attribution|distinct|user)[._-].*(?:id|key|time|token)$)|(?:^(?:device|installation|install|vendor|anonymous|distinct)[_-]?id$))", re.I)
SAFE_KEY = re.compile(r"^[A-Za-z][A-Za-z0-9_.:/-]{2,160}$")


class MachO:
    def __init__(self, data):
        self.data = data
        if data[:4] not in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"):
            raise InvalidBinary("unsupported Mach-O byte order/magic")
        self.is64 = data[:4] == b"\xcf\xfa\xed\xfe"
        self.ptrsize = 8 if self.is64 else 4
        header = unpack(data, "<7I", 0)
        self.cpu, self.subtype, self.filetype = header[1:4]
        ncmds, cmdbytes = header[4:6]
        self.header_size = 32 if self.is64 else 28
        checked(data, self.header_size, cmdbytes)
        if ncmds > cmdbytes // 8:
            raise InvalidBinary("load-command count exceeds region")
        self.commands, self.sections, self.segments, self.dylibs = [], [], [], []
        self.symtab, self.fixups, self.dyld_info = None, None, None
        self.encryption = []
        pos = self.header_size
        for _ in range(ncmds):
            cmd, size = unpack(data, "<II", pos)
            if size < 8 or pos + size > self.header_size + cmdbytes:
                raise InvalidBinary("invalid load-command size")
            minimum = {0x19: 72, 1: 56, 2: 24, 0x22: 48, 0x80000022: 48,
                       0x80000034: 16, 0x21: 20, 0x2c: 24,
                       0xc: 24, 0x80000018: 24, 0x8000001f: 24, 0x80000023: 24, 0x20: 24}.get(cmd, 8)
            if size < minimum:
                raise InvalidBinary("load command too short for its payload")
            self.commands.append({"command": hex(cmd), "offset": hex(pos), "size": size})
            if cmd in (0x19, 1):
                wide = cmd == 0x19
                prefix, secsize, segment_size = ("<16sQQQQIIII", 80, 72) if wide else ("<16sIIIIIIII", 68, 56)
                vals = unpack(data, prefix, pos + 8)
                name, addr, vmsize, off, fsize, _, _, nsects, _ = vals
                if segment_size + nsects * secsize > size:
                    raise InvalidBinary("section headers exceed segment command")
                checked(data, off, fsize)
                self.segments.append({"name": name.rstrip(b"\0").decode(), "address": addr,
                                      "vm_size": vmsize, "offset": off, "size": fsize})
                for j in range(nsects):
                    loc = pos + segment_size + j * secsize
                    sect, seg = unpack(data, "<16s16s", loc)
                    address, ssize, soff = unpack(data, "<QQI" if wide else "<III", loc + 32)
                    flags = unpack(data, "<I", loc + (64 if wide else 56))[0]
                    zero = (flags & 0xff) in (1, 0xc, 0x12)
                    if not zero:
                        checked(data, soff, ssize)
                    self.sections.append({"name": sect.rstrip(b"\0").decode(), "segment": seg.rstrip(b"\0").decode(),
                                          "address": address, "offset": soff, "size": ssize, "zerofill": zero})
            elif cmd in (0xc, 0x80000018, 0x8000001f, 0x80000023, 0x20):
                name_offset = unpack(data, "<I", pos + 8)[0]
                if name_offset < 24 or name_offset >= size:
                    raise InvalidBinary("invalid dylib name offset")
                self.dylibs.append({"name": cstr(data, pos + name_offset, pos + size), "command": hex(cmd), "offset": hex(pos)})
            elif cmd == 2:
                self.symtab = unpack(data, "<IIII", pos + 8)
            elif cmd in (0x22, 0x80000022):
                self.dyld_info = unpack(data, "<10I", pos + 8)
            elif cmd == 0x80000034:
                self.fixups = unpack(data, "<II", pos + 8)
                checked(data, *self.fixups)
            elif cmd in (0x21, 0x2c):
                cryptoff, cryptsize, cryptid = unpack(data, "<III", pos + 8)
                checked(data, cryptoff, cryptsize)
                self.encryption.append({"cryptid": cryptid, "offset": hex(pos), "encrypted_range": [hex(cryptoff), cryptsize]})
            pos += size
        if pos != self.header_size + cmdbytes:
            raise InvalidBinary("load-command region not fully consumed")
        self.image_base = min((s["address"] for s in self.segments if s["size"]), default=0)
        self.fixup_import_offsets = []
        self.imports, self.pointer_formats = self.read_fixups()
        self.classic_bindings = self.read_classic_bindings()

    def read_classic_bindings(self):
        """Resolve classic LC_DYLD_INFO bind locations (including zero pointers)."""
        if not self.dyld_info:
            return {}
        result = {}
        for off, size in (self.dyld_info[2:4], self.dyld_info[4:6], self.dyld_info[6:8]):
            stream = bytes(checked(self.data, off, size))
            pos, segment, address, symbol = 0, None, 0, None

            def leb():
                nonlocal pos
                value, shift = 0, 0
                while True:
                    byte = unpack(stream, "<B", pos)[0]
                    pos += 1
                    value |= (byte & 0x7f) << shift
                    if not byte & 0x80:
                        return value
                    shift += 7
                    if shift >= 70:
                        raise InvalidBinary("oversized bind ULEB128")

            def bind():
                if segment is None or segment >= len(self.segments) or not symbol:
                    raise InvalidBinary("bind without valid segment/symbol")
                seg = self.segments[segment]
                if address + self.ptrsize > seg["vm_size"]:
                    raise InvalidBinary(f"bind target outside segment: stream={off:#x} pos={pos:#x} segment={segment} address={address:#x} vmsize={seg['vm_size']:#x} symbol={symbol}")
                # Bindings can target zero-fill/BSS. Those have no disk pointer
                # to resolve; retain file-backed locations for reference tables.
                if address + self.ptrsize <= seg["size"]:
                    result[seg["offset"] + address] = symbol

            while pos < len(stream):
                byte = stream[pos]
                pos += 1
                op, imm = byte & 0xf0, byte & 0xf
                if op in (0x00, 0x10, 0x30, 0x50):
                    continue
                if op in (0x20, 0x60):
                    leb()  # ordinal/addend are irrelevant to imported name
                elif op == 0x40:
                    symbol = cstr(stream, pos)
                    pos = stream.find(b"\0", pos) + 1
                elif op == 0x70:
                    segment, address = imm, leb()
                elif op == 0x80:
                    address += leb()
                elif op == 0x90:
                    bind()
                    address += self.ptrsize
                elif op == 0xa0:
                    bind()
                    address += self.ptrsize + leb()
                elif op == 0xb0:
                    bind()
                    address += self.ptrsize * (1 + imm)
                elif op == 0xc0:
                    count, skip = leb(), leb()
                    if count > len(self.data) // self.ptrsize:
                        raise InvalidBinary("excessive bind repeat count")
                    for _ in range(count):
                        bind()
                        address = (address + self.ptrsize + skip) & ((1 << (8 * self.ptrsize)) - 1)
                else:
                    raise InvalidBinary(f"unsupported classic bind opcode {op:#x}")
                # dyld's uintptr_t addition wraps; some linkers encode a
                # backwards delta as a full-width unsigned ULEB128.
                address &= (1 << (8 * self.ptrsize)) - 1
        return result

    def vaoff(self, addr):
        for segment in self.segments:
            if segment["address"] <= addr < segment["address"] + segment["size"]:
                return segment["offset"] + addr - segment["address"]
        raise InvalidBinary(f"unmapped VM address {addr:#x}")

    def read_fixups(self):
        if not self.fixups:
            return [], {}
        off, size = self.fixups
        fix = bytes(checked(self.data, off, size))
        version, starts, imports, symbols, count, form, compression = unpack(fix, "<7I", 0)
        if version or compression:
            raise InvalidBinary("unsupported chained fixups version/symbol compression")
        import_sizes = {1: 4, 2: 8, 3: 16}
        if form not in import_sizes:
            raise InvalidBinary("unsupported chained import format")
        checked(fix, imports, count * import_sizes[form])
        names = []
        for i in range(count):
            at = imports + i * import_sizes[form]
            value = unpack(fix, "<Q" if form == 3 else "<I", at)[0]
            nameoff = (value >> 32) if form == 3 else (value >> 9)
            names.append(cstr(fix, symbols + nameoff))
            self.fixup_import_offsets.append(off + at)
        segments = unpack(fix, "<I", starts)[0]
        checked(fix, starts + 4, segments * 4)
        formats = {}
        for i in range(segments):
            rel = unpack(fix, "<I", starts + 4 + 4 * i)[0]
            if not rel:
                continue
            loc = starts + rel
            segsize, page_size, pointer_format, segment_offset, max_pointer, page_count = unpack(fix, "<IHHQIH", loc)
            if segsize < 22 + page_count * 2:
                raise InvalidBinary("invalid chained starts region")
            checked(fix, loc, segsize)
            formats[i] = pointer_format
        return names, formats

    def pointer(self, offset):
        if offset in self.classic_bindings:
            return None, self.classic_bindings[offset]
        value = unpack(self.data, "<Q" if self.is64 else "<I", offset)[0]
        if not self.fixups:
            return value, None
        index = next((i for i, seg in enumerate(self.segments)
                      if seg["offset"] <= offset < seg["offset"] + seg["size"]), None)
        fmt = self.pointer_formats.get(index)
        if fmt in (2, 6):  # DYLD_CHAINED_PTR_64, DYLD_CHAINED_PTR_64_OFFSET
            if value >> 63:
                ordinal = value & 0xffffff
                if ordinal >= len(self.imports):
                    raise InvalidBinary("chained import ordinal out of range")
                return None, self.imports[ordinal]
            target = value & ((1 << 36) - 1)
            high8 = (value >> 36) & 0xff
            return ((target + self.image_base) if fmt == 6 else target) | (high8 << 56), None
        if fmt in (1, 7, 9, 10, 12):
            # arm64e layouts: unauthenticated rebase has 43-bit target + high8;
            # authenticated rebases use a 32-bit image-relative target.
            auth, bind = value >> 63, (value >> 62) & 1
            if bind:
                ordinal = value & (0xffffff if fmt == 12 else 0xffff)
                if ordinal >= len(self.imports):
                    raise InvalidBinary("arm64e import ordinal out of range")
                return None, self.imports[ordinal]
            if auth:
                return self.image_base + (value & 0xffffffff), None
            target = value & ((1 << 43) - 1)
            if fmt in (7, 9, 12):
                target += self.image_base
            return target | (((value >> 43) & 0xff) << 56), None
        if fmt is None:
            return value, None
        raise InvalidBinary(f"unsupported chained pointer format {fmt}")

    def class_name(self, address):
        cls = self.vaoff(address)
        ro, imported = self.pointer(cls + 4 * self.ptrsize)
        if imported:
            return None
        ro = self.vaoff(ro & ~7)
        name, imported = self.pointer(ro + (24 if self.is64 else 16))
        return None if imported else cstr(self.data, self.vaoff(name))

    def references(self, section_name, classname=False):
        result, errors = [], []
        for section in self.sections:
            if section["name"] != section_name:
                continue
            if section["size"] % self.ptrsize:
                raise InvalidBinary("unaligned ObjC reference table")
            for off in range(section["offset"], section["offset"] + section["size"], self.ptrsize):
                try:
                    address, imported = self.pointer(off)
                    name = imported or (self.class_name(address) if classname else cstr(self.data, self.vaoff(address)))
                    if name is None:
                        raise InvalidBinary("could not resolve class name")
                    result.append({"name": name, "offset": hex(off), "imported": bool(imported)})
                except InvalidBinary as error:
                    errors.append({"offset": hex(off), "error": str(error)})
        return result, errors

    def symbols(self):
        if not self.symtab:
            return []
        off, count, stroff, strsize = self.symtab
        checked(self.data, stroff, strsize)
        stride = 16 if self.is64 else 12
        checked(self.data, off, count * stride)
        result = []
        for i in range(count):
            loc = off + i * stride
            strx, typ, section, desc, addr = unpack(self.data, "<IBBHQ" if self.is64 else "<IBBHI", loc)
            if strx >= strsize:
                raise InvalidBinary("symbol string index out of range")
            if strx and not typ & 0xe0:
                name = cstr(self.data, stroff + strx, stroff + strsize)
                result.append({"name": name, "offset": hex(loc), "address": hex(addr),
                               "undefined": (typ & 0xe) == 0, "external": bool(typ & 1), "origin": "LC_SYMTAB"})
        return result

    def swift_types(self):
        """Read ABI context descriptors, including types without ObjC classes."""
        records, errors = [], []

        def context(address, depth=0):
            if depth > 32:
                raise InvalidBinary("cyclic/deep Swift context descriptor")
            loc = self.vaoff(address)
            flags, parent = unpack(self.data, "<Ii", loc)
            kind = flags & 31
            names = []
            if parent:
                target = address + 4 + (parent & ~1)
                if parent & 1:
                    target, imported = self.pointer(self.vaoff(target))
                    if imported:
                        return [{"kind": "imported_context", "name": imported}]
                names = context(target, depth + 1)
            if kind in (0, 3, 16, 17, 18):
                rel = unpack(self.data, "<i", loc + 8)[0]
                name = cstr(self.data, self.vaoff(address + 8 + rel))
                names.append({"kind": {0: "module", 3: "protocol", 16: "class", 17: "struct", 18: "enum"}[kind], "name": name})
            else:
                names.append({"kind": f"context_{kind}", "name": "<unnamed/extension>"})
            return names

        for section in self.sections:
            if section["name"] not in ("__swift5_types", "__swift5_protos"):
                continue
            if section["size"] % 4:
                raise InvalidBinary("unaligned Swift descriptor table")
            for index in range(0, section["size"], 4):
                off = section["offset"] + index
                rel = unpack(self.data, "<i", off)[0]
                address = section["address"] + index + rel
                try:
                    records.append({"offset": hex(off), "descriptor_offset": hex(self.vaoff(address)),
                                    "table": section["name"], "context": context(address)})
                except InvalidBinary as error:
                    errors.append({"offset": hex(off), "error": str(error)})
        return records, errors

    def inventory(self):
        sels, selerr = self.references("__objc_selrefs")
        refs, referr = self.references("__objc_classrefs", True)
        classes, classerr = self.references("__objc_classlist", True)
        swift_types, swift_errors = self.swift_types()
        symbols = self.symbols()
        undefined = [s for s in symbols if s["undefined"]]
        # Newer linkers may omit dynamic imports from LC_SYMTAB altogether.
        # Preserve provenance rather than incorrectly treating them as absent.
        defined_names = {s["name"] for s in symbols if not s["undefined"]}
        known_imports = {s["name"] for s in undefined}
        bindings = [(off, name, "classic_dyld_bind_slot") for off, name in self.classic_bindings.items()]
        bindings += [(off, name, "chained_fixup_import") for off, name in zip(self.fixup_import_offsets, self.imports)]
        for off, name, origin in bindings:
            if name not in known_imports and name not in defined_names:
                undefined.append({"name": name, "offset": hex(off), "address": "0x0",
                                  "undefined": True, "external": True, "origin": origin})
                known_imports.add(name)
        modules = collections.defaultdict(list)
        for symbol in symbols + classes:
            mod = swift_module(symbol["name"])
            if mod:
                modules[mod].append(symbol)
        methods, candidates, hosts = [], [], []
        for section in self.sections:
            if section["name"] == "__objc_methname":
                methods.extend({"name": name, "offset": hex(off)} for off, name in strings(self.data, section))
            if section["name"] in ("__cstring", "__objc_methname", "__swift5_reflstr"):
                for off, name in strings(self.data, section):
                    if SAFE_KEY.fullmatch(name) and KEY_PATTERN.search(name):
                        candidates.append({"name": name, "offset": hex(off), "section": section["name"],
                                           "verdict": "candidate string only; not proof of persistent write/key"})
                    if section["name"] == "__cstring" and name.startswith(("https://", "http://", "wss://", "ws://")):
                        try:
                            host = urllib.parse.urlsplit(name).hostname
                        except ValueError:
                            host = None
                        if host and re.fullmatch(r"[A-Za-z0-9.-]{1,253}", host):
                            hosts.append({"hostname": host.lower(), "offset": hex(off),
                                          "evidence": "hostname only from static URL literal; paths/queries omitted; not observed egress"})
        apis = {}
        sources = [("selector_reference", sels), ("class_reference", refs), ("undefined_symbol", undefined)]
        for family, pattern in COMPILED_APIS.items():
            hits = []
            for kind, records in sources:
                hits.extend({"kind": kind, "name": r["name"], "offset": r["offset"]}
                            for r in records if pattern.search(r["name"]))
            apis[family] = hits
        return {
            "sha256": sha(self.data), "size": len(self.data), "cpu_type": hex(self.cpu),
            "cpu_subtype": hex(self.subtype), "file_type": self.filetype,
            "encryption": self.encryption, "dylibs": self.dylibs,
            "sections": [{**s, "address": hex(s["address"]), "offset": hex(s["offset"])} for s in self.sections],
            "chained_pointer_formats": sorted(set(self.pointer_formats.values())),
            "selector_references": sels, "class_references": refs, "class_definitions": classes,
            "swift_type_descriptors": swift_types,
            "method_name_strings": methods, "undefined_symbols": undefined,
            "unresolved_references": {"selectors": selerr, "classes": referr, "class_definitions": classerr, "swift_contexts": swift_errors},
            "swift_modules": [{"name": mod, "evidence_count": len(records), "examples": records[:8],
                               "verdict": "outer mangling-name candidate; associated-type names can resemble modules; confirm demangling or class namespace before SDK attribution"}
                              for mod, records in sorted(modules.items())],
            "api_families": apis, "storage_key_candidates": candidates, "url_host_literals": hosts,
        }


MAGICS = (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce",
          b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf", b"\xbe\xba\xfe\xca", b"\xbf\xba\xfe\xca")


def macho_slices(data):
    if data[:4] in MAGICS[:4]:
        return [(0, data)]
    if data[:4] not in MAGICS[4:]:
        raise InvalidBinary("not a Mach-O")
    endian = ">" if data[:4] in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf") else "<"
    wide = data[:4] in (b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca")
    count = unpack(data, endian + "I", 4)[0]
    size = 32 if wide else 20
    checked(data, 8, count * size)
    result = []
    for i in range(count):
        vals = unpack(data, endian + ("IIQQII" if wide else "IIIII"), 8 + size * i)
        offset, length = vals[2:4]
        result.append((offset, bytes(checked(data, offset, length))))
    return result


def inventory_ipa(path):
    hasher = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            hasher.update(block)
    result = {"schema_version": 1, "scanner": "tools/enumerate_leak_binary.py",
              "scanner_sha256": sha(open(__file__, "rb").read()),
              "ipa_sha256": hasher.hexdigest(), "ipa_size": os.path.getsize(path),
              "semantics": {
                  "selector_references": "Actual __objc_selrefs entries, not method-name strings; presence is not execution or SDK caller attribution.",
                  "class_definitions": "Names resolved through __objc_classlist -> class_ro; Swift/mangled names retained.",
                  "swift_modules": "Length-prefixed module names from symbol table/class definitions; examples are presence evidence only.",
                  "api_families": "Heuristic classification over complete raw references/undefined-symbol tables. Raw tables are authoritative for new queries.",
                  "storage_key_candidates": "Narrow string-name heuristics only. No persisted values read. Validate first-run writes separately.",
                  "negative_findings": "No reference is only a static negative for this hash. Dynamic lookup, runtime-generated names, SDK server configuration and web content remain unresolved.",
              }, "bundles": [], "mach_o_files": [], "framework_directories": [], "privacy_manifests": [], "errors": []}
    with zipfile.ZipFile(path) as archive:
        result["zip_entry_count"] = len(archive.infolist())
        frameworks = set()
        for item in sorted(archive.infolist(), key=lambda i: i.filename):
            parts = item.filename.split("/")
            for i, part in enumerate(parts):
                if part.endswith(".framework"):
                    frameworks.add("/".join(parts[:i + 1]))
            if item.is_dir():
                continue
            if item.file_size > 1024 * 1024 * 1024:
                raise InvalidBinary("single archive entry exceeds 1 GiB analysis bound")
            if parts[-1] == "PrivacyInfo.xcprivacy":
                raw = archive.read(item)
                manifest = plistlib.loads(raw)
                result["privacy_manifests"].append({"path": item.filename, "sha256": sha(raw),
                                                    "declaration_not_observed_usage": manifest})
            if parts[-1] == "Info.plist" and len(parts) >= 2 and parts[-2].endswith((".app", ".appex", ".framework", ".bundle")):
                try:
                    raw = archive.read(item)
                    info = plistlib.loads(raw)
                    fields = ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString", "CFBundleVersion", "MinimumOSVersion", "CFBundleSupportedPlatforms")
                    result["bundles"].append({"path": item.filename, "sha256": sha(raw),
                                             **{k: info[k] for k in fields if k in info}})
                except (ValueError, plistlib.InvalidFileException) as error:
                    result["errors"].append({"path": item.filename, "error": str(error)})
            with archive.open(item) as f:
                header = f.read(4)
                if header not in MAGICS:
                    continue
                data = header + f.read()
            file = {"path": item.filename, "sha256": sha(data), "size": len(data), "slices": []}
            try:
                for offset, binary in macho_slices(data):
                    file["slices"].append({"file_offset": hex(offset), **MachO(binary).inventory()})
            except InvalidBinary as error:
                file["error"] = str(error)
                result["errors"].append({"path": item.filename, "error": str(error)})
            result["mach_o_files"].append(file)
        result["framework_directories"] = sorted(frameworks)
    return result


def self_test():
    # Bounds failures must not be silently reported as absent APIs.
    valid = struct.pack("<8I", 0xfeedfacf, 0x100000c, 0, 2, 0, 0, 0, 0)
    assert MachO(valid).inventory()["selector_references"] == []
    bads = [b"", valid[:20], valid[:16] + struct.pack("<II", 1, 0) + valid[24:],
            valid[:16] + struct.pack("<II", 1, 8) + valid[24:] + struct.pack("<II", 2, 0),
            valid[:16] + struct.pack("<II", 1, 8) + valid[24:] + struct.pack("<II", 2, 100)]
    for bad in bads:
        try:
            MachO(bad).inventory()
        except InvalidBinary:
            continue
        raise AssertionError("malformed Mach-O was accepted")
    fat = b"\xca\xfe\xba\xbe" + struct.pack(">I", 1) + struct.pack(">IIIII", 0x100000c, 0, 28, len(valid), 0) + valid
    assert macho_slices(fat) == [(28, valid)]
    try:
        macho_slices(fat[:-1])
    except InvalidBinary:
        pass
    else:
        raise AssertionError("truncated fat slice was accepted")
    assert swift_module("_$s9AppsFlyer5hello") == "AppsFlyer"
    assert swift_module("_$s999bad") is None
    obj = MachO(valid)
    obj.classic_bindings = {0: "_binding_without_nlist"}
    imports = obj.inventory()["undefined_symbols"]
    assert len(imports) == 1 and imports[0]["origin"] == "classic_dyld_bind_slot"
    obj.classic_bindings = {}
    obj.data = struct.pack("<Q", 0x100001234 | (3 << 51))
    obj.segments = [{"offset": 0, "size": 8}]
    obj.fixups, obj.pointer_formats = (0, 0), {0: 2}
    obj.imports = ["_example"]
    assert obj.pointer(0) == (0x100001234, None)
    obj.data = struct.pack("<Q", (1 << 63))
    assert obj.pointer(0) == (None, "_example")
    obj.data = struct.pack("<Q", (1 << 63) | 1)
    try:
        obj.pointer(0)
    except InvalidBinary:
        pass
    else:
        raise AssertionError("out-of-bounds chained import was accepted")
    print("enumerate_leak_binary: malformed-input, import provenance and chained-pointer checks passed")


def summary_inventory(result, detail_path, detail_sha, compressed_sha):
    summary = {k: v for k, v in result.items() if k != "mach_o_files"}
    summary["full_details"] = {"file": os.path.basename(detail_path), "format": "gzip JSON; deterministic mtime=0",
                               "uncompressed_sha256": detail_sha, "gzip_sha256": compressed_sha,
                               "read": "json.load(gzip.open(path, 'rt'))"}
    summary["mach_o_files"] = []
    for binary in result["mach_o_files"]:
        out = {k: v for k, v in binary.items() if k != "slices"}
        out["slices"] = []
        for part in binary["slices"]:
            keys = ("file_offset", "sha256", "size", "cpu_type", "cpu_subtype", "file_type", "encryption",
                    "dylibs", "chained_pointer_formats", "unresolved_references", "api_families",
                    "url_host_literals", "storage_key_candidates")
            data = {k: part[k] for k in keys}
            data["counts"] = {k: len(part[k]) for k in ("selector_references", "class_references", "class_definitions",
                                                          "method_name_strings", "undefined_symbols", "swift_type_descriptors")}
            modules = collections.Counter(c["name"] for r in part["swift_type_descriptors"]
                                          for c in r["context"] if c["kind"] == "module")
            data["swift_context_modules"] = dict(sorted(modules.items()))
            out["slices"].append(data)
        summary["mach_o_files"].append(out)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", nargs="?")
    parser.add_argument("-o", "--output")
    parser.add_argument("--details-output", help="Write complete deterministic gzip JSON here, with a smaller summary at --output")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not args.ipa or not args.output:
        parser.error("IPA path and --output are required")
    result = inventory_ipa(args.ipa)
    if args.details_output:
        detail = (json.dumps(result, ensure_ascii=True, sort_keys=True, separators=(",", ":")) + "\n").encode()
        with open(args.details_output, "wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=9) as compressed:
                compressed.write(detail)
        with open(args.details_output, "rb") as f:
            compressed_sha = sha(f.read())
        result = summary_inventory(result, args.details_output, sha(detail), compressed_sha)
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2, ensure_ascii=True, sort_keys=True)
        f.write("\n")
    print(json.dumps({"ipa_sha256": result["ipa_sha256"], "mach_o_files": len(result["mach_o_files"]),
                      "frameworks": result["framework_directories"], "errors": result["errors"]}, indent=2))
    if result["errors"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
