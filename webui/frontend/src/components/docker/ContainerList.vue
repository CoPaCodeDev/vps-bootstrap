<script setup lang="ts">
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import ContainerActions from './ContainerActions.vue'
import StatusBadge from '@/components/shared/StatusBadge.vue'
import { useMobile } from '@/composables/useMobile'

defineProps<{
  containers: any[]
  host: string
  loading?: boolean
}>()

defineEmits<{
  refresh: []
}>()

const { isMobile } = useMobile()
</script>

<template>
  <!-- Mobile: Card-Liste -->
  <div v-if="isMobile" class="container-cards">
    <div v-for="c in containers" :key="c.name" class="container-card">
      <div class="card-row">
        <strong>{{ c.name }}</strong>
        <StatusBadge :status="c.state" />
      </div>
      <div class="card-detail">{{ c.image }}</div>
      <div v-if="c.ports" class="card-detail">{{ c.ports }}</div>
      <div class="card-actions">
        <ContainerActions :host="host" :container="c.name" :state="c.state" @done="$emit('refresh')" />
      </div>
    </div>
    <div v-if="containers.length === 0" class="empty">Keine Container</div>
  </div>

  <!-- Desktop: Tabelle -->
  <DataTable v-else :value="containers" :loading="loading" stripedRows size="small">
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

<style scoped>
.container-cards {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}

.container-card {
  padding: 0.75rem;
  background: var(--p-surface-card);
  border: 1px solid var(--p-surface-border);
  border-radius: var(--p-border-radius);
}

.card-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 0.25rem;
}

.card-detail {
  font-size: 0.8rem;
  color: var(--p-text-muted-color);
  word-break: break-all;
}

.card-actions {
  margin-top: 0.5rem;
  display: flex;
  gap: 0.25rem;
}

.empty {
  text-align: center;
  padding: 1rem;
  color: var(--p-text-muted-color);
}
</style>
