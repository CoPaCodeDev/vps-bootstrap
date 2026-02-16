<script setup lang="ts">
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'

defineProps<{
  servers: any[]
  loading?: boolean
}>()

defineEmits<{
  install: [serverId: string, hostname: string]
  details: [serverId: string]
}>()
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
        {{ data.serverLiveInfo?.state || '-' }}
      </template>
    </Column>
    <Column header="IP">
      <template #body="{ data }">
        <code>{{ data.ipv4Addresses?.[0]?.ip || '-' }}</code>
      </template>
    </Column>
    <Column header="Aktionen" style="width: 10rem">
      <template #body="{ data }">
        <div class="actions">
          <Button
            icon="pi pi-eye"
            text
            size="small"
            @click="$emit('details', data.id || data.serverId)"
            title="Details"
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
</style>
