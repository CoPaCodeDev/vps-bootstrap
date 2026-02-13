<script setup lang="ts">
import { ref, onMounted, onBeforeUnmount, computed } from 'vue'
import { useRoute } from 'vue-router'
import { useVpsStore } from '@/stores/vps'
import { useApi } from '@/composables/useApi'
import { useTaskStream } from '@/composables/useTaskStream'
import VpsStatusBadge from '@/components/vps/VpsStatusBadge.vue'
import LiveTerminal from '@/components/shared/LiveTerminal.vue'
import WebTerminal from '@/components/shared/WebTerminal.vue'
import ConfirmDialog from '@/components/shared/ConfirmDialog.vue'
import Card from 'primevue/card'
import Button from 'primevue/button'
import { useToast } from 'primevue/usetoast'

const route = useRoute()
const host = computed(() => route.params.host as string)
const vpsStore = useVpsStore()
const { post, get, upload } = useApi()
const toast = useToast()
const task = useTaskStream()

const status = computed(() => vpsStore.statuses[host.value])
const showRebootConfirm = ref(false)
const showTaskOutput = ref(false)
const terminalCount = ref(1)

// Upload / Dateibrowser
const showUpload = ref(false)
const browsePath = ref('/home/master')
const browseEntries = ref<{ name: string; type: string; size: string; modified: string }[]>([])
const browseLoading = ref(false)
const selectedFiles = ref<File[]>([])
const uploading = ref(false)
const fileInput = ref<HTMLInputElement | null>(null)

const breadcrumbs = computed(() => {
  const parts = browsePath.value.split('/').filter(Boolean)
  const crumbs = [{ label: '/', path: '/' }]
  let current = ''
  for (const part of parts) {
    current += '/' + part
    crumbs.push({ label: part, path: current })
  }
  return crumbs
})

async function loadDirectory(path: string) {
  browseLoading.value = true
  try {
    const data = await get<{ path: string; entries: typeof browseEntries.value }>(
      `/vps/${host.value}/files?path=${encodeURIComponent(path)}`
    )
    browsePath.value = data.path
    browseEntries.value = data.entries
  } catch {
    toast.add({ severity: 'error', summary: 'Fehler', detail: 'Verzeichnis nicht lesbar', life: 3000 })
  } finally {
    browseLoading.value = false
  }
}

function navigateTo(path: string) {
  loadDirectory(path)
}

function enterDirectory(name: string) {
  const newPath = browsePath.value === '/' ? `/${name}` : `${browsePath.value}/${name}`
  loadDirectory(newPath)
}

function onFileDrop(event: DragEvent) {
  event.preventDefault()
  if (event.dataTransfer?.files) {
    selectedFiles.value = [...selectedFiles.value, ...Array.from(event.dataTransfer.files)]
  }
}

function onFileSelect(event: Event) {
  const input = event.target as HTMLInputElement
  if (input.files) {
    selectedFiles.value = [...selectedFiles.value, ...Array.from(input.files)]
  }
}

function removeFile(index: number) {
  selectedFiles.value.splice(index, 1)
}

async function startUpload() {
  if (selectedFiles.value.length === 0) return
  uploading.value = true
  showTaskOutput.value = true

  for (const file of selectedFiles.value) {
    const formData = new FormData()
    formData.append('file', file)
    formData.append('destination', browsePath.value)
    try {
      const result = await upload<{ task_id: string }>(`/vps/${host.value}/upload`, formData)
      task.trackTask(result.task_id)
    } catch {
      toast.add({ severity: 'error', summary: 'Upload-Fehler', detail: `${file.name} fehlgeschlagen`, life: 3000 })
    }
  }

  selectedFiles.value = []
  uploading.value = false
  // Dateibrowser aktualisieren
  await loadDirectory(browsePath.value)
}

function toggleUpload() {
  showUpload.value = !showUpload.value
  if (showUpload.value) {
    loadDirectory(browsePath.value)
  }
}

let refreshInterval: ReturnType<typeof setInterval> | null = null

onMounted(async () => {
  await vpsStore.fetchHosts()
  await vpsStore.fetchStatus(host.value)
  refreshInterval = setInterval(() => vpsStore.fetchStatus(host.value), 10000)
})

onBeforeUnmount(() => {
  if (refreshInterval) clearInterval(refreshInterval)
})

async function startUpdate() {
  showTaskOutput.value = true
  await task.startTask(`/vps/${host.value}/update`)
  toast.add({ severity: 'info', summary: 'Update gestartet', life: 3000 })
}

async function confirmReboot() {
  showRebootConfirm.value = true
}

async function doReboot() {
  showRebootConfirm.value = false
  try {
    await post(`/vps/${host.value}/reboot`)
    toast.add({ severity: 'success', summary: 'Neustart', detail: 'Reboot-Befehl gesendet', life: 3000 })
  } catch {
    toast.add({ severity: 'error', summary: 'Fehler', detail: 'Reboot fehlgeschlagen', life: 3000 })
  }
}

</script>

<template>
  <div>
    <div class="page-header">
      <div>
        <h1>{{ host }}</h1>
        <VpsStatusBadge v-if="status" :online="status.online" />
      </div>
      <div class="actions">
        <Button
          label="Update"
          icon="pi pi-download"
          severity="secondary"
          @click="startUpdate"
          :disabled="task.running.value"
        />
        <Button
          :label="terminalCount === 1 ? 'Terminal teilen' : 'Terminal schließen'"
          :icon="terminalCount === 1 ? 'pi pi-clone' : 'pi pi-times'"
          :severity="terminalCount === 1 ? 'info' : 'warn'"
          :outlined="terminalCount === 1"
          @click="terminalCount = terminalCount === 1 ? 2 : 1"
        />
        <Button
          label="Hochladen"
          icon="pi pi-upload"
          severity="secondary"
          :outlined="!showUpload"
          @click="toggleUpload"
        />
        <Button
          label="Neustart"
          icon="pi pi-power-off"
          severity="danger"
          @click="confirmReboot"
        />
      </div>
    </div>

    <!-- Status-Karten -->
    <div v-if="status?.online" class="status-grid">
      <Card>
        <template #content>
          <div class="stat-card">
            <span class="stat-label">Load</span>
            <span class="stat-value">{{ status.load || '-' }}</span>
          </div>
        </template>
      </Card>
      <Card>
        <template #content>
          <div class="stat-card">
            <span class="stat-label">Uptime</span>
            <span class="stat-value">{{ status.uptime || '-' }}</span>
          </div>
        </template>
      </Card>
      <Card>
        <template #content>
          <div class="stat-card">
            <span class="stat-label">Updates</span>
            <span class="stat-value" :class="{ warn: status.updates_available > 0 }">
              {{ status.updates_available }}
            </span>
          </div>
        </template>
      </Card>
      <Card>
        <template #content>
          <div class="stat-card">
            <span class="stat-label">Kernel</span>
            <span class="stat-value small">{{ status.kernel || '-' }}</span>
          </div>
        </template>
      </Card>
      <Card>
        <template #content>
          <div class="stat-card">
            <span class="stat-label">RAM</span>
            <span class="stat-value">{{ status.memory_used }} / {{ status.memory_total }}</span>
          </div>
        </template>
      </Card>
      <Card>
        <template #content>
          <div class="stat-card">
            <span class="stat-label">Disk</span>
            <span class="stat-value">{{ status.disk_used }} / {{ status.disk_total }}</span>
          </div>
        </template>
      </Card>
    </div>

    <!-- Interaktives Terminal -->
    <Card class="section">
      <template #title>Terminal</template>
      <template #content>
        <div class="terminal-grid" :class="{ split: terminalCount === 2 }">
          <WebTerminal :host="host" :key="'term-1'" />
          <WebTerminal v-if="terminalCount === 2" :host="host" :key="'term-2'" />
        </div>
      </template>
    </Card>

    <!-- Upload mit Dateibrowser -->
    <Card v-if="showUpload" class="section">
      <template #title>Datei hochladen</template>
      <template #content>
        <div class="upload-layout">
          <!-- Links: Remote-Dateibrowser -->
          <div class="file-browser">
            <div class="breadcrumb">
              <span
                v-for="(crumb, i) in breadcrumbs"
                :key="crumb.path"
                class="crumb"
                @click="navigateTo(crumb.path)"
              >
                <span v-if="i > 0" class="crumb-sep">/</span>
                {{ crumb.label }}
              </span>
            </div>
            <div v-if="browseLoading" class="browse-loading">
              <i class="pi pi-spin pi-spinner"></i> Lade...
            </div>
            <div v-else class="file-list">
              <div
                v-for="entry in browseEntries"
                :key="entry.name"
                class="file-entry"
                :class="{ 'is-dir': entry.type === 'dir' }"
                @click="entry.type === 'dir' && enterDirectory(entry.name)"
              >
                <i :class="entry.type === 'dir' ? 'pi pi-folder' : 'pi pi-file'" class="file-icon"></i>
                <span class="file-name">{{ entry.name }}</span>
                <span class="file-size">{{ entry.type === 'file' ? entry.size : '' }}</span>
                <span class="file-modified">{{ entry.modified }}</span>
              </div>
              <div v-if="browseEntries.length === 0" class="empty-dir">Verzeichnis ist leer</div>
            </div>
          </div>
          <!-- Rechts: Upload-Zone -->
          <div class="upload-zone-container">
            <div class="upload-target">
              <i class="pi pi-folder-open"></i>
              Ziel: <strong>{{ browsePath }}</strong>
            </div>
            <div
              class="drop-zone"
              @dragover.prevent
              @drop="onFileDrop"
              @click="fileInput?.click()"
            >
              <i class="pi pi-cloud-upload drop-icon"></i>
              <p>Dateien hierher ziehen oder klicken</p>
              <input
                ref="fileInput"
                type="file"
                multiple
                class="hidden-input"
                @change="onFileSelect"
              />
            </div>
            <div v-if="selectedFiles.length > 0" class="selected-files">
              <div v-for="(file, i) in selectedFiles" :key="i" class="selected-file">
                <i class="pi pi-file"></i>
                <span>{{ file.name }}</span>
                <span class="file-size">{{ (file.size / 1024).toFixed(1) }} KB</span>
                <Button
                  icon="pi pi-times"
                  text
                  rounded
                  size="small"
                  severity="danger"
                  @click="removeFile(i)"
                />
              </div>
            </div>
            <Button
              label="Hochladen"
              icon="pi pi-upload"
              :disabled="selectedFiles.length === 0 || uploading"
              :loading="uploading"
              @click="startUpload"
              class="upload-btn"
            />
          </div>
        </div>
      </template>
    </Card>

    <!-- Task-Output -->
    <Card v-if="showTaskOutput" class="section">
      <template #title>
        <div class="task-header">
          <span>Task-Ausgabe</span>
          <Button
            icon="pi pi-times"
            text
            rounded
            size="small"
            severity="secondary"
            @click="showTaskOutput = false"
          />
        </div>
      </template>
      <template #content>
        <LiveTerminal :lines="task.output.value" :running="task.running.value" />
      </template>
    </Card>

    <!-- Reboot-Bestätigung -->
    <ConfirmDialog
      :visible="showRebootConfirm"
      header="VPS neustarten"
      :message="`Möchtest du ${host} wirklich neu starten?`"
      confirm-label="Neustarten"
      severity="danger"
      @confirm="doReboot"
      @cancel="showRebootConfirm = false"
    />
  </div>
</template>

<style scoped>
.page-header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  margin-bottom: 1.5rem;
}

.page-header h1 {
  font-size: 1.5rem;
  font-weight: 700;
  margin-bottom: 0.25rem;
}

.actions {
  display: flex;
  gap: 0.5rem;
}

.status-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));
  gap: 1rem;
  margin-bottom: 1.5rem;
}

.stat-card {
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}

.stat-label {
  font-size: 0.7rem;
  text-transform: uppercase;
  color: var(--p-text-muted-color);
  letter-spacing: 0.05em;
}

.stat-value {
  font-size: 1.125rem;
  font-weight: 600;
}

.stat-value.small {
  font-size: 0.875rem;
}

.stat-value.warn {
  color: var(--p-orange-500);
}

.section {
  margin-bottom: 1.5rem;
}

.terminal-grid {
  display: grid;
  grid-template-columns: 1fr;
  gap: 0.75rem;
}

.terminal-grid.split {
  grid-template-columns: 1fr 1fr;
}

.task-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
}

/* Upload-Layout */
.upload-layout {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 1.5rem;
}

/* Dateibrowser */
.breadcrumb {
  display: flex;
  flex-wrap: wrap;
  gap: 0.15rem;
  padding: 0.5rem 0.75rem;
  background: var(--p-surface-100);
  border-radius: var(--p-border-radius);
  margin-bottom: 0.75rem;
  font-size: 0.85rem;
}

.crumb {
  cursor: pointer;
  color: var(--p-primary-color);
}

.crumb:hover {
  text-decoration: underline;
}

.crumb-sep {
  color: var(--p-text-muted-color);
  margin: 0 0.15rem;
}

.browse-loading {
  padding: 2rem;
  text-align: center;
  color: var(--p-text-muted-color);
}

.file-list {
  max-height: 400px;
  overflow-y: auto;
  border: 1px solid var(--p-surface-200);
  border-radius: var(--p-border-radius);
}

.file-entry {
  display: grid;
  grid-template-columns: auto 1fr auto auto;
  gap: 0.5rem;
  align-items: center;
  padding: 0.4rem 0.75rem;
  border-bottom: 1px solid var(--p-surface-100);
  font-size: 0.85rem;
}

.file-entry:last-child {
  border-bottom: none;
}

.file-entry.is-dir {
  cursor: pointer;
}

.file-entry.is-dir:hover {
  background: var(--p-surface-50);
}

.file-icon {
  font-size: 0.9rem;
  color: var(--p-text-muted-color);
}

.file-entry.is-dir .file-icon {
  color: var(--p-primary-color);
}

.file-name {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.file-size,
.file-modified {
  color: var(--p-text-muted-color);
  font-size: 0.8rem;
  white-space: nowrap;
}

.empty-dir {
  padding: 2rem;
  text-align: center;
  color: var(--p-text-muted-color);
}

/* Upload-Zone */
.upload-zone-container {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
}

.upload-target {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.5rem 0.75rem;
  background: var(--p-surface-100);
  border-radius: var(--p-border-radius);
  font-size: 0.85rem;
}

.drop-zone {
  border: 2px dashed var(--p-surface-300);
  border-radius: var(--p-border-radius);
  padding: 2rem;
  text-align: center;
  cursor: pointer;
  transition: border-color 0.2s, background 0.2s;
}

.drop-zone:hover {
  border-color: var(--p-primary-color);
  background: var(--p-surface-50);
}

.drop-icon {
  font-size: 2rem;
  color: var(--p-text-muted-color);
  margin-bottom: 0.5rem;
}

.drop-zone p {
  color: var(--p-text-muted-color);
  font-size: 0.85rem;
  margin: 0;
}

.hidden-input {
  display: none;
}

.selected-files {
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}

.selected-file {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.3rem 0.5rem;
  background: var(--p-surface-50);
  border-radius: var(--p-border-radius);
  font-size: 0.85rem;
}

.selected-file .file-size {
  margin-left: auto;
}

.upload-btn {
  align-self: flex-end;
}
</style>
