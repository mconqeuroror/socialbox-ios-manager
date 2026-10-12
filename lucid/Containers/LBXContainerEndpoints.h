#pragma once
// Fixed build-time private root path. The installer creates this store during
// explicit first installation; service startup opens it without recreating it.
#ifndef LBX_CONTAINER_STORE_PATH
#define LBX_CONTAINER_STORE_PATH "/var/jb/var/lib/socialbox-container-configurations"
#endif
// Established root pending state is initialized only by explicit trusted setup
// after genuine pairing and a held, verified-empty configuration namespace.
// Ordinary service startup never creates, adopts or resets this leaf.
#ifndef LBX_CONTAINER_PENDING_PATH
#define LBX_CONTAINER_PENDING_PATH "/var/jb/var/lib/socialbox-container-pending"
#endif
