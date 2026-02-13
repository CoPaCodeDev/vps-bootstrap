<script setup lang="ts">
import { ref, onMounted, computed } from 'vue'
import { useRoute } from 'vue-router'
import { useVpsStore, type VPSStatus } from '@/stores/vps'
import { useApi } from '@/composables/useApi'
import { useTaskStream } from '@/composables/useTaskStream'
import VpsStatusBadge from '@/components/vps/VpsStatusBadge.vue'
import LiveTerminal from '@/components/shared/LiveTerminal.vue'
import ConfirmDialog from '@/components/shared/ConfirmDialog.vue'
import Card from 'primevue/card'
import Button from 'primevue/button'
import InputText from 'primevue/inputtext'
import { useToast } from 'primevue/usetoast'

const route = useRoute()
const host = computed(() => route.params.host as string)
const vpsStore = useVpsStore()
const { post } = useApi()
const toast = useToast()
const task = useTaskStream()

const status = computed(() => vpsStore.statuses[host.value])
const execCommand = ref('')
const execOutput = ref('')
const execLoading = ref(false)
const showRebootConfirm = ref(false)

onMounted(async () => {
  await vpsStore.fetchHosts()
  await vpsStore.fetchStatus(host.value)
})

async function startUpdate() {
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

async function runExec() {
  if (!execCommand.value.trim()) return
  execLoading.value = true
  execOutput.value = ''
  try {
    const result = await post<{ exit_code: number; stdout: string; stderr: string }>(
      `/vps/${host.value}/exec`,
      { command: execCommand.value },
    )
    execOutput.value = result.stdout + (result.stderr ? '\n' + result.stderr : '')
  } catch (e: any) {
    execOutput.value = `Fehler: ${e.detail || e}`
  } finally {
    execLoading.value = false
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
          label="Aktualisieren"
          icon="pi pi-refresh"
          text
          @click="vpsStore.fetchStatus(host)"
        />
        <Button
          label="Update"
          icon="pi pi-download"
          severity="secondary"
          @click="startUpdate"
          :disabled="task.running.value"
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

    <!-- Befehl ausführen -->
    <Card class="section">
      <template #title>Befehl ausführen</template>
      <template #content>
        <div class="exec-form">
          <InputText
            v-model="execCommand"
            placeholder="z.B. df -h, htop, docker ps"
            class="exec-input"
            @keyup.enter="runExec"
          />
          <Button
            label="Ausführen"
            icon="pi pi-play"
            @click="runExec"
            :loading="execLoading"
          />
        </div>
        <LiveTerminal
          v-if="execOutput"
          :lines="execOutput.split('\n')"
          class="exec-terminal"
        />
      </template>
    </Card>

    <!-- Task-Output -->
    <Card v-if="task.output.value.length > 0" class="section">
      <template #title>Task-Ausgabe</template>
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

.exec-form {
  display: flex;
  gap: 0.5rem;
  margin-bottom: 0.75rem;
}

.exec-input {
  flex: 1;
}

.exec-terminal {
  margin-top: 0.75rem;
}
</style>
