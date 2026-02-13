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
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Tree from 'primevue/tree'
import type { TreeNode } from 'primevue/treenode'
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
const browseEntries = ref<{ name: string; type: string; size: string; modified: string; permissions: string }[]>([])
const browseLoading = ref(false)
const selectedFiles = ref<File[]>([])
const uploading = ref(false)
const fileInput = ref<HTMLInputElement | null>(null)
const browseHistory = ref<string[]>([])
const historyIndex = ref(-1)

// Tree
const treeNodes = ref<TreeNode[]>([])
const selectedTreeKey = ref<Record<string, boolean>>({})
const expandedKeys = ref<Record<string, boolean>>({})
const treeInitialized = ref(false)

const folderCount = computed(() => browseEntries.value.filter(e => e.type === 'dir').length)
const fileCount = computed(() => browseEntries.value.filter(e => e.type === 'file').length)

function fileIcon(name: string): string {
  const ext = name.includes('.') ? name.slice(name.lastIndexOf('.')).toLowerCase() : ''
  if (['.jpg', '.jpeg', '.png', '.gif', '.svg', '.webp', '.bmp'].includes(ext)) return 'pi-image'
  if (['.zip', '.tar', '.gz', '.bz2', '.xz', '.7z', '.rar'].includes(ext)) return 'pi-box'
  if (['.sh', '.py', '.js', '.ts', '.go', '.rs', '.c', '.cpp', '.java'].includes(ext)) return 'pi-code'
  if (['.txt', '.md', '.log', '.conf', '.cfg', '.ini', '.yaml', '.yml', '.toml', '.json'].includes(ext)) return 'pi-file-edit'
  if (ext === '.pdf') return 'pi-file-pdf'
  return 'pi-file'
}

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

async function loadDirectory(path: string, addToHistory = true) {
  browseLoading.value = true
  try {
    const data = await get<{ path: string; entries: typeof browseEntries.value }>(
      `/vps/${host.value}/files?path=${encodeURIComponent(path)}`
    )
    browsePath.value = data.path
    browseEntries.value = data.entries
    selectedTreeKey.value = { [data.path]: true }
    if (addToHistory) {
      // Truncate forward history when navigating to a new path
      browseHistory.value = browseHistory.value.slice(0, historyIndex.value + 1)
      browseHistory.value.push(data.path)
      historyIndex.value = browseHistory.value.length - 1
    }
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

function goBack() {
  if (historyIndex.value > 0) {
    historyIndex.value--
    loadDirectory(browseHistory.value[historyIndex.value], false)
  }
}

function goUp() {
  if (browsePath.value === '/') return
  const parent = browsePath.value.substring(0, browsePath.value.lastIndexOf('/')) || '/'
  loadDirectory(parent)
}

async function loadTreeChildren(path: string): Promise<TreeNode[]> {
  try {
    const data = await get<{ path: string; entries: typeof browseEntries.value }>(
      `/vps/${host.value}/files?path=${encodeURIComponent(path)}`
    )
    return data.entries
      .filter(e => e.type === 'dir')
      .map(e => ({
        key: path === '/' ? `/${e.name}` : `${path}/${e.name}`,
        label: e.name,
        icon: 'pi pi-folder',
        leaf: false,
        children: [] as TreeNode[]
      }))
  } catch {
    return []
  }
}

async function initTree() {
  const rootChildren = await loadTreeChildren('/')
  treeNodes.value = rootChildren
  expandedKeys.value = {}
  // Automatisch bis /home/master expandieren
  const pathParts = '/home/master'.split('/').filter(Boolean)
  let currentPath = ''
  for (const part of pathParts) {
    currentPath += '/' + part
    expandedKeys.value[currentPath] = true
    // Node im Baum finden und Kinder laden
    const node = findTreeNode(treeNodes.value, currentPath)
    if (node) {
      node.children = await loadTreeChildren(currentPath)
    }
  }
  selectedTreeKey.value = { [browsePath.value]: true }
  treeInitialized.value = true
}

function findTreeNode(nodes: TreeNode[], key: string): TreeNode | null {
  for (const node of nodes) {
    if (node.key === key) return node
    if (node.children) {
      const found = findTreeNode(node.children, key)
      if (found) return found
    }
  }
  return null
}

async function onTreeExpand(node: TreeNode) {
  if (!node.children || node.children.length === 0) {
    node.children = await loadTreeChildren(node.key as string)
  }
}

function onTreeSelect(node: TreeNode) {
  loadDirectory(node.key as string)
}

function downloadFile(name: string) {
  const filePath = browsePath.value === '/' ? `/${name}` : `${browsePath.value}/${name}`
  const url = `/api/v1/vps/${host.value}/download?path=${encodeURIComponent(filePath)}`
  window.open(url, '_blank')
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
    if (!treeInitialized.value) {
      initTree()
    }
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
      <template #title>
        <div class="card-header-with-close">
          <span>Datei hochladen</span>
          <Button
            icon="pi pi-times"
            text
            rounded
            size="small"
            severity="secondary"
            @click="showUpload = false"
          />
        </div>
      </template>
      <template #content>
        <div class="upload-layout">
          <!-- Oben: Tree + Dateibrowser -->
          <div class="browser-row">
            <div class="tree-panel">
              <Tree
                :value="treeNodes"
                v-model:selectionKeys="selectedTreeKey"
                v-model:expandedKeys="expandedKeys"
                selectionMode="single"
                class="explorer-tree"
                @node-expand="onTreeExpand"
                @node-select="onTreeSelect"
              />
            </div>
            <div class="file-browser">
            <!-- Explorer-Toolbar -->
            <div class="explorer-toolbar">
              <div class="explorer-nav">
                <Button
                  icon="pi pi-arrow-left"
                  text
                  rounded
                  size="small"
                  :disabled="historyIndex <= 0"
                  @click="goBack"
                  v-tooltip.bottom="'Zurück'"
                />
                <Button
                  icon="pi pi-arrow-up"
                  text
                  rounded
                  size="small"
                  :disabled="browsePath === '/'"
                  @click="goUp"
                  v-tooltip.bottom="'Übergeordneter Ordner'"
                />
              </div>
              <div class="explorer-breadcrumb">
                <span
                  v-for="(crumb, i) in breadcrumbs"
                  :key="crumb.path"
                  class="crumb"
                  @click="navigateTo(crumb.path)"
                >
                  <span v-if="i > 0" class="crumb-sep"><i class="pi pi-chevron-right"></i></span>
                  {{ crumb.label }}
                </span>
              </div>
              <div class="explorer-view-toggle">
                <Button
                  icon="pi pi-refresh"
                  text
                  rounded
                  size="small"
                  @click="loadDirectory(browsePath)"
                  v-tooltip.bottom="'Aktualisieren'"
                />
              </div>
            </div>

            <!-- Loading -->
            <div v-if="browseLoading" class="browse-loading">
              <i class="pi pi-spin pi-spinner"></i> Lade...
            </div>

            <!-- Dateiliste -->
            <div v-else class="explorer-list">
              <DataTable
                :value="browseEntries"
                size="small"
                stripedRows
                scrollable
                scrollHeight="flex"
                @row-dblclick="(e: any) => e.data.type === 'dir' && enterDirectory(e.data.name)"
                class="explorer-table"
              >
                <Column field="name" header="Name" sortable style="min-width: 200px">
                  <template #body="{ data }">
                    <div class="list-name-cell">
                      <i
                        :class="data.type === 'dir' ? 'pi pi-folder' : `pi ${fileIcon(data.name)}`"
                        class="list-icon"
                        :style="data.type === 'dir' ? 'color: #e8a838' : ''"
                      ></i>
                      <span :class="{ 'dir-name': data.type === 'dir' }">{{ data.name }}</span>
                    </div>
                  </template>
                </Column>
                <Column field="size" header="Größe" sortable style="width: 100px">
                  <template #body="{ data }">
                    {{ data.type === 'file' ? data.size : '' }}
                  </template>
                </Column>
                <Column field="permissions" header="Rechte" sortable style="width: 120px">
                  <template #body="{ data }">
                    <span class="permissions-cell">{{ data.permissions }}</span>
                  </template>
                </Column>
                <Column field="modified" header="Geändert" sortable style="width: 160px" />
                <Column header="" style="width: 50px; text-align: center">
                  <template #body="{ data }">
                    <Button
                      v-if="data.type === 'file'"
                      icon="pi pi-download"
                      text
                      rounded
                      size="small"
                      severity="secondary"
                      @click="downloadFile(data.name)"
                      v-tooltip.bottom="'Herunterladen'"
                    />
                  </template>
                </Column>
              </DataTable>
              <div v-if="browseEntries.length === 0" class="empty-dir">Verzeichnis ist leer</div>
            </div>

            <!-- Statusleiste -->
            <div class="explorer-statusbar">
              {{ folderCount }} Ordner, {{ fileCount }} Dateien
            </div>
          </div>
          </div>
          <!-- Unten: Upload-Zone -->
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
  display: flex;
  flex-direction: column;
  gap: 1.5rem;
}

.browser-row {
  display: grid;
  grid-template-columns: 220px 1fr;
  gap: 1rem;
  height: 500px;
}

.file-browser {
  display: flex;
  flex-direction: column;
  min-height: 0;
}

.card-header-with-close {
  display: flex;
  justify-content: space-between;
  align-items: center;
}

/* Tree-Panel */
.tree-panel {
  overflow-y: auto;
  border-right: 1px solid var(--p-surface-200);
  padding-right: 0.5rem;
}

.explorer-tree :deep(.p-tree) {
  padding: 0;
  border: none;
  background: transparent;
}

.explorer-tree :deep(.p-tree-node-label) {
  font-size: 0.8rem;
}

.explorer-tree :deep(.p-tree-node-content) {
  padding: 0.15rem 0.35rem;
  border-radius: 4px;
}

.explorer-tree :deep(.p-tree-node-content:hover) {
  background: var(--p-surface-100);
}

.explorer-tree :deep(.p-tree-node-content.p-tree-node-selected) {
  background: var(--p-primary-100);
  color: var(--p-primary-700);
}

.explorer-tree :deep(.p-tree-node-icon) {
  color: #e8a838;
  font-size: 0.9rem;
}

.explorer-tree :deep(.p-tree-toggler) {
  width: 1.25rem;
  height: 1.25rem;
}

/* Explorer-Toolbar */
.explorer-toolbar {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.35rem 0.5rem;
  background: var(--p-surface-100);
  border-radius: var(--p-border-radius);
  margin-bottom: 0.75rem;
}

.explorer-nav {
  display: flex;
  gap: 0.1rem;
  flex-shrink: 0;
}

.explorer-breadcrumb {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.1rem;
  flex: 1;
  min-width: 0;
  font-size: 0.85rem;
  padding: 0 0.25rem;
}

.crumb {
  cursor: pointer;
  color: var(--p-primary-color);
  display: inline-flex;
  align-items: center;
  gap: 0.1rem;
}

.crumb:hover {
  text-decoration: underline;
}

.crumb-sep {
  color: var(--p-text-muted-color);
  font-size: 0.65rem;
  margin: 0 0.1rem;
}

/* Loading */
.browse-loading {
  padding: 2rem;
  text-align: center;
  color: var(--p-text-muted-color);
}

/* Listen-Ansicht */
.explorer-list {
  border: 1px solid var(--p-surface-200);
  border-radius: var(--p-border-radius);
  overflow: hidden;
  flex: 1;
  min-height: 0;
}

.explorer-table :deep(.p-datatable-row-action) {
  cursor: pointer;
}

.list-name-cell {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.list-icon {
  font-size: 1.1rem;
  flex-shrink: 0;
  color: var(--p-text-muted-color);
}

.dir-name {
  font-weight: 500;
}

.permissions-cell {
  font-family: monospace;
  font-size: 0.8rem;
  color: var(--p-text-muted-color);
}

/* Statusleiste */
.explorer-statusbar {
  display: flex;
  align-items: center;
  padding: 0.35rem 0.75rem;
  font-size: 0.8rem;
  color: var(--p-text-muted-color);
  border-top: 1px solid var(--p-surface-100);
  margin-top: 0.5rem;
}

.empty-dir {
  padding: 2rem;
  text-align: center;
  color: var(--p-text-muted-color);
  grid-column: 1 / -1;
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
