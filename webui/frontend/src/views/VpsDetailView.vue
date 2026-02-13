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
const { post } = useApi()
const toast = useToast()
const task = useTaskStream()

const status = computed(() => vpsStore.statuses[host.value])
const showRebootConfirm = ref(false)
const showTaskOutput = ref(false)
const terminalCount = ref(1)

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
</style>
