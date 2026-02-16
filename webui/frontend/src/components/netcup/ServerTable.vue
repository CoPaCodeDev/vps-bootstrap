<script setup lang="ts">
import { ref } from 'vue'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import { useApi } from '@/composables/useApi'
import { useToast } from 'primevue/usetoast'

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
const actionLoading = ref<Record<string, boolean>>({})

async function serverAction(serverId: string, action: string) {
  actionLoading.value[`${serverId}-${action}`] = true
  try {
    await post(`/netcup/servers/${serverId}/state/${action}`)
    const labels: Record<string, string> = { start: 'gestartet', stop: 'gestoppt', restart: 'neugestartet' }
    toast.add({ severity: 'success', summary: `Server ${labels[action]}`, life: 3000 })
    emit('refresh')
  } catch (e: any) {
    toast.add({ severity: 'error', summary: 'Fehler', detail: e.detail, life: 5000 })
  } finally {
    actionLoading.value[`${serverId}-${action}`] = false
  }
}
</script>

<template>
  <DataTable :value="servers" :loading="loading" stripedRows>
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
          <Button
            icon="pi pi-play"
            text
            size="small"
            severity="success"
            @click="serverAction(data.id, 'start')"
            :loading="actionLoading[`${data.id}-start`]"
            :disabled="data.serverLiveInfo?.state === 'RUNNING'"
            title="Starten"
          />
          <Button
            icon="pi pi-stop"
            text
            size="small"
            severity="danger"
            @click="serverAction(data.id, 'stop')"
            :loading="actionLoading[`${data.id}-stop`]"
            :disabled="data.serverLiveInfo?.state !== 'RUNNING'"
            title="Stoppen"
          />
          <Button
            icon="pi pi-refresh"
            text
            size="small"
            severity="warn"
            @click="serverAction(data.id, 'restart')"
            :loading="actionLoading[`${data.id}-restart`]"
            :disabled="data.serverLiveInfo?.state !== 'RUNNING'"
            title="Neustarten"
          />
          <Button
            icon="pi pi-download"
            text
            size="small"
            severity="secondary"
            @click="$emit('install', data.id || data.serverId, data.hostname || '')"
            title="Installieren"
          />
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
</style>
