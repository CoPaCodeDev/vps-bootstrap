<script setup lang="ts">
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'

defineProps<{
  snapshots: any[]
  loading?: boolean
}>()

defineEmits<{
  restore: [snapshotId: string]
}>()

function formatTime(iso: string) {
  if (!iso) return '-'
  try {
    return new Date(iso).toLocaleString('de-DE')
  } catch {
    return iso
  }
}
</script>

<template>
  <DataTable :value="snapshots" :loading="loading" stripedRows size="small">
    <Column field="short_id" header="ID" style="width: 6rem">
      <template #body="{ data }">
        <code>{{ data.short_id }}</code>
      </template>
    </Column>
    <Column field="time" header="Zeitpunkt" sortable>
      <template #body="{ data }">
        {{ formatTime(data.time) }}
      </template>
    </Column>
    <Column field="hostname" header="Hostname" />
    <Column field="paths" header="Pfade">
      <template #body="{ data }">
        {{ (data.paths || []).join(', ') }}
      </template>
    </Column>
    <Column header="Aktionen" style="width: 6rem">
      <template #body="{ data }">
        <Button
          icon="pi pi-history"
          text
          size="small"
          @click="$emit('restore', data.id)"
          title="Wiederherstellen"
        />
      </template>
    </Column>
    <template #empty>Keine Snapshots vorhanden</template>
  </DataTable>
</template>
