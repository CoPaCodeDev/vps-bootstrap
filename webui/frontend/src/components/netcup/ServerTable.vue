<script setup lang="ts">
import { ref } from 'vue'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import { useApi } from '@/composables/useApi'
import { useToast } from 'primevue/usetoast'
import { useMobile } from '@/composables/useMobile'

defineProps<{
  servers: any[]
  loading?: boolean
}>()

const emit = defineEmits<{
  install: [serverId: string, hostname: string]
  refresh: []
}>()

const { post } = useApi()
const toast = useToast()
const { isMobile } = useMobile()
const actionLoading = ref<Record<string, boolean>>({})

async function serverAction(serverId: string, action: string) {
  actionLoading.value[`${serverId}-${action}`] = true
  try {
    await post(`/netcup/servers/${serverId}/state/${action}`)
    const labels: Record<string, string> = { start: 'gestartet', stop: 'gestoppt', restart: 'neugestartet' }
    toast.add({ severity: 'success', summary: `Server ${labels[action]}`, life: 3000 })
    emit('refresh')
    setTimeout(() => emit('refresh'), 5000)
    setTimeout(() => emit('refresh'), 15000)
  } catch (e: any) {
    toast.add({ severity: 'error', summary: 'Fehler', detail: e.detail, life: 5000 })
  } finally {
    actionLoading.value[`${serverId}-${action}`] = false
  }
}
</script>

<template>
  <!-- Mobile: Card-Liste -->
  <div v-if="isMobile" class="server-cards">
    <div v-for="s in servers" :key="s.id || s.serverId" class="server-card">
      <div class="card-header">
        <strong>{{ s.name || s.serverName || '-' }}</strong>
        <span class="card-state">{{ s.serverLiveInfo?.state || (s.disabled ? 'deaktiviert' : 'aktiv') }}</span>
      </div>
      <div v-if="s.nickname" class="card-detail">{{ s.nickname }}</div>
      <div class="card-detail">
        <span v-if="s.ipv4Addresses?.length">
          <code v-for="addr in s.ipv4Addresses" :key="addr.id">{{ addr.ip }}</code>
        </span>
        <span v-if="s.vlanIp"> VLAN: <code>{{ s.vlanIp }}</code></span>
      </div>
      <div class="card-actions">
        <Button icon="pi pi-play" text size="small" severity="success" @click="serverAction(s.id, 'start')" :loading="actionLoading[`${s.id}-start`]" :disabled="s.serverLiveInfo?.state === 'RUNNING'" title="Starten" />
        <Button icon="pi pi-stop" text size="small" severity="danger" @click="serverAction(s.id, 'stop')" :loading="actionLoading[`${s.id}-stop`]" :disabled="s.serverLiveInfo?.state !== 'RUNNING'" title="Stoppen" />
        <Button icon="pi pi-refresh" text size="small" severity="warn" @click="serverAction(s.id, 'restart')" :loading="actionLoading[`${s.id}-restart`]" :disabled="s.serverLiveInfo?.state !== 'RUNNING'" title="Neustarten" />
        <Button icon="pi pi-download" text size="small" severity="secondary" @click="$emit('install', s.id || s.serverId, s.hostname || '')" title="Installieren" />
      </div>
    </div>
    <div v-if="servers.length === 0" class="empty">Keine Server gefunden</div>
  </div>

  <!-- Desktop: Tabelle -->
  <DataTable v-else :value="servers" :loading="loading" stripedRows>
    <Column header="ID" style="width: 5rem">
      <template #body="{ data }">
        {{ data.id || data.serverId }}
      </template>
    </Column>
    <Column header="Name">
      <template #body="{ data }">
        {{ data.name || data.serverName || '-' }}
      </template>
    </Column>
    <Column header="Spitzname">
      <template #body="{ data }">
        {{ data.nickname || '-' }}
      </template>
    </Column>
    <Column header="Status">
      <template #body="{ data }">
        {{ data.serverLiveInfo?.state || (data.disabled ? 'deaktiviert' : 'aktiv') }}
      </template>
    </Column>
    <Column header="IP">
      <template #body="{ data }">
        <div v-if="data.ipv4Addresses?.length">
          <code v-for="addr in data.ipv4Addresses" :key="addr.id" class="ip-addr">
            {{ addr.ip }}
          </code>
        </div>
        <span v-else>-</span>
      </template>
    </Column>
    <Column header="CloudVLAN">
      <template #body="{ data }">
        <code v-if="data.vlanIp">{{ data.vlanIp }}</code>
        <span v-else>-</span>
      </template>
    </Column>
    <Column header="Aktionen" style="width: 14rem">
      <template #body="{ data }">
        <div class="actions">
          <Button icon="pi pi-play" text size="small" severity="success" @click="serverAction(data.id, 'start')" :loading="actionLoading[`${data.id}-start`]" :disabled="data.serverLiveInfo?.state === 'RUNNING'" title="Starten" />
          <Button icon="pi pi-stop" text size="small" severity="danger" @click="serverAction(data.id, 'stop')" :loading="actionLoading[`${data.id}-stop`]" :disabled="data.serverLiveInfo?.state !== 'RUNNING'" title="Stoppen" />
          <Button icon="pi pi-refresh" text size="small" severity="warn" @click="serverAction(data.id, 'restart')" :loading="actionLoading[`${data.id}-restart`]" :disabled="data.serverLiveInfo?.state !== 'RUNNING'" title="Neustarten" />
          <Button icon="pi pi-download" text size="small" severity="secondary" @click="$emit('install', data.id || data.serverId, data.hostname || '')" title="Installieren" />
        </div>
      </template>
    </Column>
    <template #empty>Keine Server gefunden</template>
  </DataTable>
</template>

<style scoped>
.actions {
  display: flex;
  gap: 0.25rem;
}

.ip-addr {
  display: block;
}

.server-cards {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}

.server-card {
  padding: 0.75rem;
  background: var(--p-surface-card);
  border: 1px solid var(--p-surface-border);
  border-radius: var(--p-border-radius);
}

.server-card .card-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 0.25rem;
}

.card-state {
  font-size: 0.75rem;
  color: var(--p-text-muted-color);
  text-transform: uppercase;
}

.card-detail {
  font-size: 0.8rem;
  color: var(--p-text-muted-color);
}

.card-detail code {
  font-size: 0.8rem;
}

.card-actions {
  display: flex;
  gap: 0.25rem;
  margin-top: 0.5rem;
}

.empty {
  text-align: center;
  padding: 1rem;
  color: var(--p-text-muted-color);
}
</style>
