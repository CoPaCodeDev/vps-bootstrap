<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useVpsStore } from '@/stores/vps'
import VpsStatusCard from '@/components/vps/VpsStatusCard.vue'
import Button from 'primevue/button'
import { useApi } from '@/composables/useApi'
import { useToast } from 'primevue/usetoast'

const vpsStore = useVpsStore()
const { post } = useApi()
const toast = useToast()
const scanning = ref(false)

onMounted(async () => {
  await vpsStore.fetchHosts()
  vpsStore.fetchAllStatuses()
})

async function startScan() {
  scanning.value = true
  try {
    await post('/vps/scan')
    toast.add({ severity: 'info', summary: 'Scan gestartet', detail: 'Netzwerk-Scan läuft im Hintergrund', life: 3000 })
  } catch {
    toast.add({ severity: 'error', summary: 'Fehler', detail: 'Scan konnte nicht gestartet werden', life: 3000 })
  } finally {
    scanning.value = false
  }
}

async function refresh() {
  await vpsStore.fetchHosts()
  vpsStore.fetchAllStatuses()
}

const managedHosts = computed(() => vpsStore.hosts.filter((h) => h.managed !== false))
const unmanagedHosts = computed(() => vpsStore.hosts.filter((h) => h.managed === false))
</script>

<template>
  <div>
    <div class="page-header">
      <h1>VPS-Übersicht</h1>
      <div class="actions">
        <Button
          label="Aktualisieren"
          icon="pi pi-refresh"
          text
          @click="refresh"
          :loading="vpsStore.loading"
        />
        <Button
          label="Netzwerk scannen"
          icon="pi pi-search"
          severity="secondary"
          @click="startScan"
          :loading="scanning"
        />
      </div>
    </div>

    <div v-if="vpsStore.loading && vpsStore.hosts.length === 0" class="loading">
      <i class="pi pi-spin pi-spinner" style="font-size: 2rem"></i>
      <p>Lade VPS-Liste...</p>
    </div>

    <div v-else-if="vpsStore.hosts.length === 0" class="empty-state">
      <i class="pi pi-server" style="font-size: 3rem; color: var(--p-text-muted-color)"></i>
      <h3>Keine VPS gefunden</h3>
      <p>Starte einen Netzwerk-Scan, um VPS zu finden.</p>
      <Button label="Netzwerk scannen" icon="pi pi-search" @click="startScan" />
    </div>

    <template v-else>
      <div class="vps-grid">
        <VpsStatusCard
          v-for="vps in managedHosts"
          :key="vps.ip"
          :vps="vps"
          :status="vpsStore.statuses[vps.name]"
        />
      </div>

      <div v-if="unmanagedHosts.length > 0" class="unmanaged-section">
        <h2>Weitere Geräte im Netzwerk</h2>
        <div class="vps-grid">
          <VpsStatusCard
            v-for="vps in unmanagedHosts"
            :key="vps.ip"
            :vps="vps"
            :status="vpsStore.statuses[vps.name]"
          />
        </div>
      </div>
    </template>
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

.actions {
  display: flex;
  gap: 0.5rem;
}

.vps-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
  gap: 1rem;
}

.loading, .empty-state {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  padding: 4rem 2rem;
  gap: 1rem;
  color: var(--p-text-muted-color);
}

.empty-state h3 {
  color: var(--p-text-color);
}

.unmanaged-section {
  margin-top: 2rem;
}

.unmanaged-section h2 {
  font-size: 1.15rem;
  font-weight: 600;
  margin-bottom: 1rem;
  color: var(--p-text-muted-color);
}
</style>
