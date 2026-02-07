# API-Referenz: VPS Installation

Alle Endpunkte und Schemas der Netcup SCP REST API, die für die automatische
VPS-Installation benötigt werden.

> Base-URL: `https://www.servercontrolpanel.de/scp-core`
> Vollständige OpenAPI-Spec: [netcup-scp-openapi.json](netcup-scp-openapi.json)

---

## Endpunkte

### 1. Server auflisten

```
GET /api/v1/servers
```

**Query-Parameter:**

| Parameter | Typ     | Beschreibung         |
|-----------|---------|----------------------|
| `q`       | string  | Allgemeine Suche     |
| `name`    | string  | Filter nach Name     |
| `ip`      | string  | Filter nach IP       |
| `limit`   | integer | Ergebnisse begrenzen |
| `offset`  | integer | Ergebnisse versetzt  |

**Response (200):** Array von `ServerListMinimal`

---

### 2. Server-Details abrufen

```
GET /api/v1/servers/{serverId}
```

**Path-Parameter:** `serverId` (integer)

**Query-Parameter:**

| Parameter            | Typ     | Beschreibung                    |
|----------------------|---------|---------------------------------|
| `loadServerLiveInfo` | boolean | Live-Infos (State, IPs) laden   |

**Response (200):** `Server`-Objekt (inkl. `serverLiveInfo` wenn angefragt)
**Response (404):** Server nicht gefunden

---

### 3. Verfügbare Images abrufen

```
GET /api/v1/servers/{serverId}/imageflavours
```

**Path-Parameter:** `serverId` (integer)

**Response (200):** Array von `ImageFlavour`
**Response (404):** Server nicht gefunden

> Für die Installation wird das Debian 13 Image anhand des `name`-Feldes identifiziert.

---

### 4. Disks abrufen

```
GET /api/v1/servers/{serverId}/disks
```

**Path-Parameter:** `serverId` (integer)

**Response (200):** Array von `Disk`

---

### 5. SSH-Keys auflisten

```
GET /api/v1/users/{userId}/ssh-keys
```

**Path-Parameter:** `userId` (integer)

**Response (200):** Array von `SSHKey`

---

### 6. SSH-Key hochladen

```
POST /api/v1/users/{userId}/ssh-keys
```

**Path-Parameter:** `userId` (integer)

**Request-Body:**

```json
{
  "name": "proxy-key",
  "key": "ssh-ed25519 AAAA..."
}
```

| Feld   | Typ    | Pflicht | Beschreibung                    |
|--------|--------|---------|---------------------------------|
| `name` | string | ja      | Name des Keys (max 255 Zeichen) |
| `key`  | string | ja      | Public Key (max 4096 Zeichen)   |

**Response (201):** Erstelltes `SSHKey`-Objekt (mit `id`)
**Response (422):** Validierungsfehler

---

### 7. Image installieren

```
POST /api/v1/servers/{serverId}/image
```

**Path-Parameter:** `serverId` (integer)

> **ACHTUNG:** Alle Daten auf der gewählten Disk werden gelöscht!

**Request-Body:**

```json
{
  "imageFlavourId": 67,
  "diskName": "vda",
  "rootPartitionFullDiskSize": true,
  "hostname": "webshop",
  "locale": "de_DE",
  "timezone": "Europe/Berlin",
  "additionalUserUsername": "master",
  "additionalUserPassword": "Sicheres1Passwort",
  "sshKeyIds": [42],
  "sshPasswordAuthentication": false,
  "customScript": "#!/bin/bash\nset -e\n...",
  "emailToExecutingUser": false
}
```

| Feld                        | Typ       | Pflicht | Beschreibung                                                             |
|-----------------------------|-----------|---------|--------------------------------------------------------------------------|
| `imageFlavourId`            | integer   | ja      | ID des zu installierenden Images                                         |
| `diskName`                  | string    | ja      | Ziel-Disk (z.B. `vda`)                                                  |
| `rootPartitionFullDiskSize` | boolean   | nein    | Volle Disk für Root-Partition nutzen                                     |
| `hostname`                  | string    | nein    | Hostname für die Installation                                            |
| `locale`                    | string    | nein    | Locale (z.B. `de_DE`)                                                   |
| `timezone`                  | string    | nein    | Zeitzone (z.B. `Europe/Berlin`)                                         |
| `additionalUserUsername`    | string    | nein    | Benutzername (Regex: `^[a-z][a-z0-9_]{0,30}$`)                         |
| `additionalUserPassword`    | string    | nein    | Passwort (min 8 Zeichen, Groß+Klein+Zahl)                              |
| `sshKeyIds`                 | integer[] | nein    | IDs der SSH-Keys die autorisiert werden                                  |
| `sshPasswordAuthentication` | boolean   | nein    | SSH-Passwort-Auth erlauben                                               |
| `customScript`              | string    | nein    | Post-Install-Script                                                      |
| `emailToExecutingUser`      | boolean   | nein    | E-Mail-Benachrichtigung senden                                           |

**Passwort-Regex:** `^(?=.*[A-Z])(?=.*[a-z])(?=.*[0-9])[A-Za-z0-9!-~]{8,}$`

**Response (202):** `TaskInfo`-Objekt (asynchrone Verarbeitung)
**Response (422):** Validierungsfehler

---

### 8. CloudVLAN-Interface anlegen

```
POST /api/v1/servers/{serverId}/interfaces
```

**Path-Parameter:** `serverId` (integer)

**Request-Body:**

```json
{
  "vlanId": 12345,
  "networkDriver": "VIRTIO"
}
```

| Feld            | Typ     | Pflicht | Beschreibung                                      |
|-----------------|---------|---------|---------------------------------------------------|
| `vlanId`        | integer | ja      | VLAN-ID                                            |
| `networkDriver` | string  | ja      | Enum: `VIRTIO`, `E1000`, `E1000E`, `RTL8139`, `VMXNET3` |

**Response (202):** `TaskInfo`-Objekt
**Response (400):** Max 10 Interfaces pro Server
**Response (422):** Validierungsfehler

---

### 9. Hostname / Nickname setzen

```
PATCH /api/v1/servers/{serverId}
```

**Path-Parameter:** `serverId` (integer)

> Pro Request darf nur **ein** Attribut geändert werden.

**Hostname setzen:**

```json
{ "hostname": "webshop" }
```

**Nickname setzen:**

```json
{ "nickname": "webshop" }
```

**Server starten/stoppen:**

```json
{ "state": "ON" }
```

| State       | Beschreibung     |
|-------------|------------------|
| `ON`        | Server starten   |
| `OFF`       | Server stoppen   |
| `SUSPENDED` | Server pausieren |

**Response (200):** Synchron erledigt
**Response (202):** `TaskInfo`-Objekt (asynchron)
**Response (503):** Node in Wartung

---

## Schemas

### Server

| Feld                      | Typ                  | Beschreibung               |
|---------------------------|----------------------|----------------------------|
| `id`                      | integer              | Server-ID                  |
| `name`                    | string               | Servername                 |
| `hostname`                | string?              | Hostname                   |
| `nickname`                | string?              | Nickname                   |
| `disabled`                | boolean              | Deaktiviert                |
| `ipv4Addresses`           | IPv4AddressMinimal[] | IPv4-Adressen              |
| `ipv6Addresses`           | IPv6AddressMinimal[] | IPv6-Adressen              |
| `architecture`            | string               | `AMD64` oder `ARM64`       |
| `serverLiveInfo`          | ServerInfo?          | Live-Infos (optional)      |
| `site`                    | Site                 | Rechenzentrum              |
| `maxCpuCount`             | integer              | Max CPUs                   |
| `disksAvailableSpaceInMiB`| integer              | Freier Speicher in MiB     |

### ServerInfo (Live-Infos)

| Feld                | Typ               | Beschreibung              |
|---------------------|--------------------|--------------------------|
| `state`             | ServerState        | Aktueller Zustand         |
| `interfaces`        | ServerInterface[]  | Netzwerk-Interfaces       |
| `disks`             | ServerDisk[]       | Disks                     |
| `uptimeInSeconds`   | integer            | Uptime in Sekunden        |
| `cpuCount`          | integer            | CPU-Anzahl                |
| `currentServerMemoryInMiB` | integer     | RAM in MiB                |

**ServerState-Enum:** `NOSTATE`, `RUNNING`, `BLOCKED`, `PAUSED`, `SHUTDOWN`, `SHUTOFF`, `CRASHED`, `PMSUSPENDED`, `DISK_SNAPSHOT`

### ImageFlavour

| Feld    | Typ     | Beschreibung               |
|---------|---------|----------------------------|
| `id`    | integer | Image-ID                   |
| `name`  | string  | Image-Name (max 255)       |
| `alias` | string  | Image-Alias (max 255)      |
| `text`  | string  | Beschreibung (max 10000)   |

### Disk

| Feld              | Typ     | Beschreibung                       |
|-------------------|---------|------------------------------------|
| `name`            | string  | Disk-Name (z.B. `vda`)            |
| `capacityInMiB`   | integer | Kapazität in MiB                   |
| `allocationInMiB` | integer | Belegter Speicher in MiB           |
| `storageDriver`   | string  | `VIRTIO`, `VIRTIO_SCSI`, `IDE`, `SATA` |

### SSHKey

| Feld        | Typ      | Beschreibung               |
|-------------|----------|-----------------------------|
| `id`        | integer  | Key-ID                      |
| `name`      | string   | Key-Name (max 255)          |
| `key`       | string   | Public Key (max 4096)       |
| `createdAt` | datetime | Erstellt am                 |

### TaskInfo

| Feld               | Typ          | Beschreibung               |
|--------------------|--------------|-----------------------------|
| `uuid`             | string       | Task-UUID                   |
| `name`             | string       | Task-Name                   |
| `state`            | TaskState    | Status                      |
| `startedAt`        | datetime     | Gestartet um                |
| `finishedAt`       | datetime?    | Beendet um                  |
| `taskProgress`     | TaskProgress | Fortschritt                 |
| `message`          | string?      | Nachricht                   |
| `steps`            | TaskInfoStep[] | Einzelschritte            |
| `responseError`    | ResponseError? | Fehler (bei `ERROR`)      |

**TaskState-Enum:** `PENDING`, `RUNNING`, `FINISHED`, `ERROR`, `WAITING_FOR_CANCEL`, `CANCELED`, `ROLLBACK`

### TaskProgress

| Feld                  | Typ      | Beschreibung                |
|-----------------------|----------|-----------------------------|
| `progressInPercent`   | number   | Fortschritt in Prozent (0-100) |
| `expectedFinishedAt`  | datetime? | Voraussichtliche Fertigstellung |
