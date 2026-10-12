# SocialBoxCLI (source rebuild)

Theos rootless `TOOL` for A/B/A: `list` / `create` / `activate` / `verify`.
Speaks `com.socialbox.helper.xpc`.

```
SocialBoxCLI list [--json]
SocialBoxCLI create --name A --apps ig,fb [--no-activate]
SocialBoxCLI activate 1
SocialBoxCLI verify --container 1 [--json]
SocialBoxCLI container verify-isolation com.burbn.instagram --container 1 --json
```

Install path: `/var/jb/usr/local/bin/SocialBoxCLI` (root peer, hash-pinned when digests set).
