#!/usr/bin/env python3
"""Portable Debian package safety inspection and deterministic flat APT indexes."""
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import tarfile
from urllib.parse import urlsplit
from package_variant import VARIANTS, variant, render_script

PACKAGE = "com.redditbox"
ARCHITECTURE = "iphoneos-arm64"
MAX_PACKAGE = 512 * 1024 * 1024
MAX_METADATA = 4 * 1024 * 1024
VERSION = re.compile(r"(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\Z")
HASH = re.compile(r"[0-9a-f]{64}\Z")
HOST = re.compile(r"[a-z0-9][a-z0-9-]*\.public\.blob\.vercel-storage\.com\Z")
DEPENDENCIES = {"ai.akemi.appinst": r"2\.1\.1(?:-redditbox[1-9][0-9]{0,3})?", "ai.akemi.appsyncunified": r"116\.0"}
APP_IDS = {
    "var/jb/Applications/RedditBox.app/Info.plist": "com.redditbox.launcher",
    "var/jb/Applications/RedditBoxFirewall.app/Info.plist": "com.redditbox.firewall",
    "var/jb/Applications/RedditBoxFirewall.app/PlugIns/PacketTunnel.appex/Info.plist": "com.redditbox.firewall.PacketTunnel",
}
PAYLOAD_PREFIXES = (
    "var/jb/Applications/RedditBox.app/",
    "var/jb/Applications/RedditBoxFirewall.app/",
    "var/jb/Applications/SocialBoxFacebook.app/",
    "var/jb/Library/PreferenceBundles/RedditBoxPrefs.bundle/",
)
PAYLOAD_FILES = {
    "var/jb/usr/bin/redditboxd", "var/jb/usr/bin/redditbox-profile",
    "var/jb/usr/libexec/redditbox-keychain-cleaner",
    "var/jb/Library/LaunchDaemons/com.redditbox.daemon.plist",
    "var/jb/Library/MobileSubstrate/DynamicLibraries/RedditBox.dylib",
    "var/jb/Library/MobileSubstrate/DynamicLibraries/RedditBox.plist",
    "var/jb/Library/PreferenceLoader/Preferences/RedditBoxPrefs.plist",
    *{"var/jb/usr/share/redditbox/" + name for name in (
        "catalog.json", "isolation_audit.py", "smoke-log-order.awk", "on-device-smoke.sh",
        "com.redditbox.rotation.example.plist", "release.json")},
}


def architecture_variant(architecture):
    for scheme, config in VARIANTS.items():
        if config["architecture"] == architecture:
            return scheme, config
    raise ValueError("Unsupported jailbreak package architecture")


def payload_layout(architecture):
    scheme, config = architecture_variant(architecture)
    convert = lambda path: path if scheme == "rootless" else path.removeprefix("var/jb/")
    return ({convert(path): identity for path, identity in APP_IDS.items()},
            tuple(convert(path) for path in PAYLOAD_PREFIXES), {convert(path) for path in PAYLOAD_FILES})


def require(condition, message):
    if not condition:
        raise ValueError(message)


def version_tuple(value):
    require(isinstance(value, str) and VERSION.fullmatch(value), "Version must be canonical X.Y.Z with components 0–9999")
    return tuple(map(int, value.split(".")))


def next_version(current, published=None, requested=None):
    baseline = max(version_tuple(current), version_tuple(published) if published else (0, 0, 0))
    if requested:
        chosen = version_tuple(requested)
    else:
        chosen = list(baseline)
        for index in (2, 1, 0):
            if chosen[index] < 9999:
                chosen[index] += 1
                break
            chosen[index] = 0
        else:
            raise ValueError("Version space exhausted")
        chosen = tuple(chosen)
    require(not published or chosen > version_tuple(published), "Release version must be greater than the published version")
    return ".".join(map(str, chosen))


def parse_fields(text):
    result = {}
    key = None
    for line in text.splitlines():
        if not line:
            continue
        if line[0].isspace():
            require(key is not None, "Unexpected control continuation")
            result[key] += "\n" + line
            continue
        key, separator, value = line.partition(":")
        require(separator and re.fullmatch(r"[A-Za-z][A-Za-z0-9-]*", key), "Invalid control field")
        require(key not in result, "Duplicate control field")
        result[key] = value.lstrip()
    return result


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def archive_members(data):
    require(data.startswith(b"!<arch>\n"), "Package is not a Debian ar archive")
    offset, result = 8, {}
    while offset < len(data):
        require(offset + 60 <= len(data), "Truncated ar header")
        header = data[offset:offset + 60]
        require(header[58:] == b"`\n", "Invalid ar header")
        name = header[:16].decode("ascii").strip().rstrip("/")
        require(re.fullmatch(r"[A-Za-z0-9_.+-]+", name) and name not in result, "Unsafe or duplicate ar member")
        try:
            size = int(header[48:58].strip())
        except ValueError as error:
            raise ValueError("Invalid ar size") from error
        offset += 60
        require(0 <= size <= MAX_PACKAGE and offset + size <= len(data), "Truncated or oversized ar member")
        result[name] = data[offset:offset + size]
        offset += size + size % 2
    require(offset == len(data), "Invalid ar padding")
    require(result.get("debian-binary") == b"2.0\n", "Unsupported Debian package format")
    return result


def normalized_member(name):
    require(isinstance(name, str) and "\\" not in name and "\x00" not in name, "Unsafe tar member name")
    while name.startswith("./"):
        name = name[2:]
    require(not name.startswith("/") and ".." not in PurePosixPath(name).parts, "Tar path escapes package root")
    return name.rstrip("/")


def tar_entries(data):
    total, count, names = 0, 0, set()
    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as archive:
            for member in archive:
                name = normalized_member(member.name)
                if not name or name == ".":
                    require(member.isdir(), "Invalid archive root")
                    continue
                count += 1
                total += member.size
                require(count <= 50000 and total <= MAX_PACKAGE, "Expanded package exceeds safety bounds")
                require(name not in names, "Duplicate tar payload path")
                names.add(name)
                require(member.isdir() or member.isfile(), "Links and special files are forbidden in the package")
                require(not member.mode & 0o6000, "Setuid/setgid payload is forbidden")
                yield name, member, archive
    except (tarfile.TarError, EOFError, OSError) as error:
        raise ValueError("Cannot inspect package compression; use gzip/xz/bzip2/uncompressed Debian tar members") from error


def read_member(archive, member, limit=MAX_METADATA):
    require(member.size <= limit, "Metadata member exceeds safety bounds")
    stream = archive.extractfile(member)
    require(stream is not None, "Metadata member is unreadable")
    data = stream.read(limit + 1)
    require(len(data) == member.size and len(data) <= limit, "Truncated metadata member")
    return data


def package_control(path):
    data = Path(path).read_bytes()
    require(0 < len(data) <= MAX_PACKAGE, "Debian package size is outside safety bounds")
    members = archive_members(data)
    controls = [name for name in members if name.startswith("control.tar")]
    payloads = [name for name in members if name.startswith("data.tar")]
    require(len(controls) == len(payloads) == 1 and len(members) == 3, "Expected exactly control/data/debian-binary members")
    files = {}
    for name, member, archive in tar_entries(members[controls[0]]):
        require(member.isfile(), "Unexpected control directory")
        require(name in {"control", "postinst", "prerm", "postrm", "preinst", "md5sums", "conffiles"}, "Unexpected maintainer control file")
        files[name] = read_member(archive, member)
    require("control" in files, "Missing Debian control")
    return data, members[payloads[0]], parse_fields(files["control"].decode("utf-8")), files


def inspect_package(path, expected_version, scripts_directory=None, scheme="rootless"):
    config = variant(scheme)
    architecture = config["architecture"]
    app_ids, payload_prefixes, payload_files = payload_layout(architecture)
    version_tuple(expected_version)
    data, payload, control, scripts = package_control(path)
    require(control.get("Package") == PACKAGE, "Unexpected Debian package ID")
    require(control.get("Architecture") == architecture, "Package architecture does not match the selected jailbreak variant")
    require(control.get("Version") == expected_version, "Debian package version does not match requested release")
    require(control.get("Description"), "Debian package description is missing")
    require(not scripts.get("conffiles", b"").strip(), "Package must not claim ownership of user configuration files")
    for name in ("preinst", "postinst", "prerm", "postrm"):
        if name not in scripts:
            require(name == "preinst", "Required maintainer script is missing: " + name)
            continue
        script = scripts[name].decode("utf-8").replace("\r\n", "\n")
        commands = "\n".join(line for line in script.splitlines() if not line.lstrip().startswith("#"))
        require("/var/mobile/" not in commands and "/var/containers/" not in commands, "Maintainer script references user data")
        require(not re.search(r"\b(?:rm|rmdir|unlink|appinst)\s", commands), "Maintainer scripts must not delete data or clone installations")
        require(not re.search(r"\buicache\s+-a\b", commands), "Global uicache registration is forbidden")
        if scripts_directory:
            reviewed = Path(scripts_directory) / name
            require(reviewed.is_file() and render_script(reviewed.read_text(encoding="utf-8"), scheme).replace("\r\n", "\n") == script,
                    "Packaged maintainer script differs from reviewed checkout: " + name)
    allowed_directories = {str(parent) for path in (*payload_files, *payload_prefixes) for parent in PurePosixPath(path).parents}
    allowed_directories.update(path.rstrip("/") for path in payload_prefixes)
    seen, infos, release = set(), {}, None
    for name, member, archive in tar_entries(payload):
        if member.isdir():
            require(name in allowed_directories or name.startswith(payload_prefixes), "Payload directory outside the selected install tree")
            require(not any(part.lower() in {"mobile", "containers", "profiles", "journals", "sourceinbox"} for part in PurePosixPath(name).parts),
                    "User data directory in package")
            continue
        require(name in payload_files or name.startswith(payload_prefixes), "Unexpected payload path: " + name)
        basename = PurePosixPath(name).name.lower()
        require(not basename.endswith((".ipa", ".p12", ".pfx", ".key", ".pem")), "Private keys or imported application archives must not ship")
        require(not any(token in basename for token in ("com.redditbox.store", "com.redditbox.profiles", "network-lease", "launcher-state", "transaction", "journal", "license-private")),
                "User state or transaction data in package")
        seen.add(name)
        if name.endswith("/Info.plist"):
            info = plistlib.loads(read_member(archive, member))
            require(isinstance(info, dict), "Invalid packaged Info.plist")
            identifier = info.get("CFBundleIdentifier", "")
            require(identifier != "com.reddit.Reddit" and not identifier.startswith("com.redditbox.profile."), "Source or clone app must not ship in distribution")
            infos[name] = info
        if name == (config["prefix"] + "/usr/share/redditbox/release.json").lstrip("/"):
            release = json.loads(read_member(archive, member))
    entry_info = ("var/jb/" if scheme == "rootless" else "") + "Applications/SocialBoxFacebook.app/Info.plist"
    if entry_info in infos:
        app_ids[entry_info] = "com.socialbox.facebook.entry"
    require(payload_files.issubset(seen), "Package is missing expected installed components: " + ", ".join(sorted(payload_files - seen)))
    for name, identifier in app_ids.items():
        info = infos.get(name, {})
        require(info.get("CFBundleIdentifier") == identifier, "Stable bundle identifier changed: " + name)
        require(info.get("CFBundleVersion") == expected_version and info.get("CFBundleShortVersionString") == expected_version,
                "App/extension version does not match package: " + name)
    require(isinstance(release, dict) and release.get("version") == expected_version, "Package release metadata is missing or mismatched")
    require(type(release.get("schemaVersion")) is int and release["schemaVersion"] == 2, "Unsupported packaged schema version")
    require(isinstance(release.get("signingContractHash"), str) and HASH.fullmatch(release["signingContractHash"]), "Missing signing contract hash")
    require(type(release.get("requiresMDMReadoption")) is bool, "Missing explicit MDM re-adoption flag")
    require(release.get("packageScheme", "rootless") == scheme and
            release.get("packageArchitecture", ARCHITECTURE) == architecture and
            release.get("installPrefix", "/var/jb") == config["prefix"], "Release metadata belongs to another jailbreak variant")
    filename = f"debs/{PACKAGE}_{expected_version}_{architecture}.deb"
    return {"version": expected_version, "filename": filename, "sha256": sha256(data), "size": len(data),
            "control": control, "release": release}


def validate_manifest(manifest, host, architecture=ARCHITECTURE):
    _, config = architecture_variant(architecture)
    require(HOST.fullmatch(host or ""), "APT_BLOB_HOST must be the exact dedicated public Blob hostname")
    require(isinstance(manifest, dict) and type(manifest.get("formatVersion")) is int and manifest["formatVersion"] == 1, "Unsupported repository manifest")
    require(manifest.get("package") == PACKAGE and manifest.get("architecture") == architecture, "Repository identity mismatch")
    require(manifest.get("blobHost") == host, "Repository public Blob host differs from configured host")
    entries = manifest.get("versions")
    require(isinstance(entries, list) and 1 <= len(entries) <= 3, "Repository must index one to three versions")
    versions, names = [], set()
    for entry in entries:
        require(isinstance(entry, dict), "Invalid repository version record")
        version = entry.get("version")
        versions.append(version_tuple(version))
        filename = f"debs/{PACKAGE}_{version}_{architecture}.deb"
        require(entry.get("filename") == filename and filename not in names, "Invalid or duplicate package filename")
        names.add(filename)
        require(isinstance(entry.get("sha256"), str) and HASH.fullmatch(entry["sha256"]), "Invalid package SHA256")
        require(type(entry.get("size")) is int and 0 < entry["size"] <= MAX_PACKAGE, "Invalid package size")
        expected_url = f"https://{host}/apt/{config['repository']}/debs/{entry['sha256']}/{PurePosixPath(filename).name}"
        require(entry.get("blobURL") == expected_url, "Untrusted package redirect URL")
        control = entry.get("control")
        require(isinstance(control, dict) and all(isinstance(k, str) and isinstance(v, str) for k, v in control.items()), "Invalid stored Debian control")
        require(control.get("Package") == PACKAGE and control.get("Architecture") == architecture and control.get("Version") == version, "Stored Debian identity mismatch")
    require(versions == sorted(set(versions), reverse=True), "Repository versions must be distinct newest-first")
    require(manifest.get("version") == entries[0]["version"], "Repository head version mismatch")
    require(isinstance(manifest.get("signingContractHash"), str) and HASH.fullmatch(manifest["signingContractHash"]), "Repository signing contract is missing")
    require(type(manifest.get("requiresMDMReadoption")) is bool, "Repository must explicitly state whether MDM re-adoption is required")
    validate_dependencies(manifest.get('dependencies', []), host, architecture)
    indexes = manifest.get("previousIndexes", [])
    require(isinstance(indexes, list) and len(indexes) <= 6, "Too many retained index hashes")
    index_names = set()
    for index in indexes:
        require(isinstance(index, dict) and HASH.fullmatch(index.get("sha256", "")), "Invalid retained index")
        require(index.get("path") == "by-hash/SHA256/" + index["sha256"] and index["path"] not in index_names, "Invalid retained index path")
        require(type(index.get("size")) is int and 0 < index["size"] <= MAX_METADATA, "Invalid retained index size")
        index_names.add(index["path"])
    return manifest


def validate_dependencies(entries, host, architecture):
    _, config = architecture_variant(architecture)
    require(isinstance(entries, list) and len(entries) <= len(DEPENDENCIES), "Invalid dependency inventory")
    seen = set()
    for entry in entries:
        require(isinstance(entry, dict) and isinstance(entry.get('control'), dict), "Invalid dependency record")
        control = entry['control']; package = control.get('Package'); version = entry.get('version', '')
        require(package in DEPENDENCIES and package not in seen and isinstance(version, str) and re.fullmatch(DEPENDENCIES[package], version), "Unsupported or duplicate dependency")
        seen.add(package)
        filename = f"{package}_{version}_{architecture}.deb"
        require(control.get('Architecture') == architecture and control.get('Version') == version, "Dependency identity mismatch")
        require(entry.get('filename') == 'debs/' + filename and HASH.fullmatch(entry.get('sha256', '')), "Invalid dependency path or digest")
        require(type(entry.get('size')) is int and 0 < entry['size'] <= MAX_PACKAGE, "Invalid dependency size")
        require(entry.get('blobURL') == f"https://{host}/apt/{config['repository']}/debs/{entry['sha256']}/{filename}", "Untrusted dependency URL")
    return entries


def repository_entries(manifest):
    return manifest['versions'] + manifest.get('dependencies', [])


def packages_bytes(entries):
    paragraphs = []
    for entry in entries:
        fields = {key: value for key, value in entry["control"].items() if key not in {"Filename", "Size", "SHA256", "SHA1", "MD5sum"}}
        fields.update(Filename=entry["filename"], Size=str(entry["size"]), SHA256=entry["sha256"])
        lines = []
        for key in sorted(fields):
            value = fields[key]
            require(re.fullmatch(r"[A-Za-z][A-Za-z0-9-]*", key), "Invalid control field name")
            require(isinstance(value, str) and "\r" not in value and all(line.startswith((" ", "\t")) for line in value.split("\n")[1:]), "Invalid control continuation")
            lines.append(key + ": " + value)
        paragraphs.append("\n".join(lines))
    return ("\n\n".join(paragraphs) + "\n\n").encode("utf-8")


def generate_repository(entry, previous, host, published_at, old_indexes=None):
    architecture = entry["control"]["Architecture"]
    architecture_variant(architecture)
    if previous: validate_manifest(previous, host, architecture)
    old_indexes = old_indexes or {}
    previous_entries = previous["versions"] if previous else []
    require(not previous or version_tuple(entry["version"]) > version_tuple(previous["version"]), "Cannot publish an equal/older version")
    versions = [entry] + previous_entries[:2]
    manifest = {"formatVersion": 1, "package": PACKAGE, "architecture": architecture,
                "version": entry["version"], "versions": versions, "blobHost": host,
                "publishedAt": published_at,
                "signingContractHash": entry["release"]["signingContractHash"],
                "requiresMDMReadoption": entry["release"]["requiresMDMReadoption"]}
    if previous and 'dependencies' in previous:
        manifest['dependencies'] = previous['dependencies']
    return repository_files(manifest, (previous or {}).get('previousIndexes', []), old_indexes)


def dependency_repository(previous, entries, host, old_indexes):
    validate_manifest(previous, host, previous['architecture'])
    validate_dependencies(entries, host, previous['architecture'])
    manifest = dict(previous, dependencies=entries)
    return repository_files(manifest, previous.get('previousIndexes', []), old_indexes)


def repository_files(manifest, previous_indexes, old_indexes):
    packages = packages_bytes(repository_entries(manifest))
    compressed = gzip.compress(packages, mtime=0)
    files = {"Packages": packages, "Packages.gz": compressed}
    indexes = []
    for data in (packages, compressed):
        digest = sha256(data)
        path = "by-hash/SHA256/" + digest
        files[path] = data
        indexes.append({"path": path, "sha256": digest, "size": len(data)})
    for index in previous_indexes[:4]:
        data = old_indexes.get(index["path"])
        require(data is not None and sha256(data) == index["sha256"] and len(data) == index["size"], "Retained APT index is missing or corrupt")
        if index["path"] not in files:
            files[index["path"]] = data
            indexes.append(index)
    manifest['previousIndexes'] = indexes
    validate_manifest(manifest, manifest['blobHost'], manifest['architecture'])
    files["repository.json"] = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    return manifest, files


def release_bytes(files, date, architecture=ARCHITECTURE):
    architecture_variant(architecture)
    text = ("Origin: RedditBox\nLabel: RedditBox\nSuite: stable\nCodename: redditbox\n"
            f"Architectures: {architecture}\nComponents: main\nDescription: RedditBox packages\n"
            f"Date: {date}\nAcquire-By-Hash: yes\nSHA256:\n")
    for name in ("Packages", "Packages.gz", "repository.json"):
        data = files[name]
        text += f" {sha256(data)} {len(data)} {name}\n"
    return text.encode()


def signed_checksums(release, architecture=ARCHITECTURE):
    architecture_variant(architecture)
    fields = parse_fields(release.decode("utf-8"))
    require(fields.get("Origin") == "RedditBox" and fields.get("Architectures") == architecture, "Signed repository identity mismatch")
    result = {}
    for line in fields.get("SHA256", "").splitlines():
        if not line.strip():
            continue
        parts = line.split()
        require(len(parts) == 3 and HASH.fullmatch(parts[0]), "Invalid signed checksum line")
        digest, size, path = parts
        require(path in {"Packages", "Packages.gz", "repository.json"} and path not in result, "Unexpected signed index path")
        require(size.isdecimal() and 0 < int(size) <= MAX_METADATA, "Signed index size exceeds bounds")
        result[path] = {"sha256": digest, "size": int(size)}
    require(set(result) == {"Packages", "Packages.gz", "repository.json"}, "Signed indexes are incomplete")
    return result
