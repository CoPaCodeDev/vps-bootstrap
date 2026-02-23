<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useApi } from '@/composables/useApi'
import { useTaskStream } from '@/composables/useTaskStream'
import BackupStatusCard from '@/components/backup/BackupStatusCard.vue'
import SnapshotList from '@/components/backup/SnapshotList.vue'
import RestoreDialog from '@/components/backup/RestoreDialog.vue'
import LiveTerminal from '@/components/shared/LiveTerminal.vue'
import Card from 'primevue/card'
import Button from 'primevue/button'
import Select from 'primevue/select'
import { useVpsStore } from '@/stores/vps'
import { useToast } from 'primevue/usetoast'
import { useMobile } from '@/composables/useMobile'

const { isMobile } = useMobile()
const { get, post, loading } = useApi()
const vpsStore = useVpsStore()
const toast = useToast()
const task = useTaskStream()

const backupStatuses = ref<any[]>([])
const selectedHost = ref('')
const snapshots = ref<any[]>([])
const snapshotsLoading = ref(false)
const showRestore = ref(false)
const restoreSnapshotId = ref('')

onMounted(async () => {
  await vpsStore.fetchHosts()
  fetchStatus()
})

async function fetchStatus() {
  backupStatuses.value = await get<any[]>('/backup/status')
}

async function loadSnapshots() {
  if (!selectedHost.value) return
  snapshotsLoading.value = true
  try {
    snapshots.value = await get<any[]>(`/backup/${selectedHost.value}/snapshots`)
  } finally {
    snapshotsLoading.value = false
  }
}

async function runBackup() {
  if (!selectedHost.value) return
  await task.startTask(`/backup/${selectedHost.value}/run`)
  toast.add({ severity: 'info', summary: 'Backup gestartet', life: 3000 })
}

function startRestore(snapshotId: string) {
  restoreSnapshotId.value = snapshotId
  showRestore.value = true
}

async function doRestore(data: any) {
  if (!selectedHost.value) return
  await task.startTask(`/backup/${selectedHost.value}/restore`, data)
  toast.add({ severity: 'info', summary: 'Wiederherstellung gestartet', life: 3000 })
}

const hostOptions = vpsStore.hosts.map((h) => ({ label: h.name, value: h.name }))
</script>

<template>
  <div>
    <div class="page-header">
      <h1>Backup-Verwaltung</h1>
      <Button :label="isMobile ? undefined : 'Aktualisieren'" icon="pi pi-refresh" text @click="fetchStatus" :loading="loading" />
    </div>

    <!-- Status-Karten -->
    <div class="status-grid">
      <BackupStatusCard
        v-for="s in backupStatuses"
        :key="s.host"
        :status="s"
      />
    </div>

    <!-- Host-Auswahl für Snapshots -->
    <Card class="section">
      <template #title>Snapshots & Aktionen</template>
      <template #content>
        <div class="host-select">
          <Select
            v-model="selectedHost"
            :options="hostOptions"
            optionLabel="label"
            optionValue="value"
            placeholder="Host auswählen..."
            @change="loadSnapshots"
            class="host-dropdown"
          />
          <Button
            :label="isMobile ? undefined : 'Snapshots laden'"
            icon="pi pi-list"
            severity="secondary"
            @click="loadSnapshots"
            :disabled="!selectedHost"
          />
          <Button
            :label="isMobile ? undefined : 'Backup ausführen'"
            icon="pi pi-play"
            @click="runBackup"
            :disabled="!selectedHost || task.running.value"
          />
        </div>

        <SnapshotList
          v-if="snapshots.length > 0"
          :snapshots="snapshots"
          :loading="snapshotsLoading"
          @restore="startRestore"
          class="mt"
        />
      </template>
    </Card>

    <!-- Task-Output -->
    <Card v-if="task.output.value.length > 0" class="section">
      <template #title>Ausgabe</template>
      <template #content>
        <LiveTerminal :lines="task.output.value" :running="task.running.value" />
      </template>
    </Card>

    <!-- Restore-Dialog -->
    <RestoreDialog
      v-model:visible="showRestore"
      :snapshot-id="restoreSnapshotId"
      :host="selectedHost"
      @confirm="doRestore"
    />
  </div>
</template>

<style scoped>
.page-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 1.5rem;
}

.page-header h1 {
  font-size: 1.5rem;
  font-weight: 700;
}

.status-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
  gap: 1rem;
  margin-bottom: 1.5rem;
}

.section {
  margin-bottom: 1.5rem;
}

.host-select {
  display: flex;
  gap: 0.5rem;
  align-items: center;
  flex-wrap: wrap;
}

.host-dropdown {
  min-width: 180px;
}

.mt {
  margin-top: 1rem;
}

@media (max-width: 767px) {
  .host-dropdown {
    width: 100%;
  }
}
</style>
