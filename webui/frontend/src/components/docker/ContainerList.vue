<script setup lang="ts">
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import ContainerActions from './ContainerActions.vue'
import StatusBadge from '@/components/shared/StatusBadge.vue'

defineProps<{
  containers: any[]
  host: string
  loading?: boolean
}>()

defineEmits<{
  refresh: []
}>()
</script>

<template>
  <DataTable :value="containers" :loading="loading" stripedRows size="small">
    <Column field="name" header="Name" sortable />
    <Column field="image" header="Image" sortable />
    <Column field="state" header="Status">
      <template #body="{ data }">
        <StatusBadge :status="data.state" />
      </template>
    </Column>
    <Column field="status" header="Details" />
    <Column field="ports" header="Ports" />
    <Column header="Aktionen" style="width: 8rem">
      <template #body="{ data }">
        <ContainerActions :host="host" :container="data.name" :state="data.state" @done="$emit('refresh')" />
      </template>
    </Column>
    <template #empty>Keine Container</template>
  </DataTable>
</template>
