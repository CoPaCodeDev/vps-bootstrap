<script setup lang="ts">
import LiveTerminal from '@/components/shared/LiveTerminal.vue'
import StatusBadge from '@/components/shared/StatusBadge.vue'
import Card from 'primevue/card'

defineProps<{
  lines: string[]
  running: boolean
  status: string
}>()
</script>

<template>
  <Card>
    <template #title>
      <div class="progress-header">
        <span>Deployment-Fortschritt</span>
        <StatusBadge v-if="status" :status="status" />
        <span v-else-if="running" class="running-text">
          <i class="pi pi-spin pi-spinner"></i> Läuft...
        </span>
      </div>
    </template>
    <template #content>
      <LiveTerminal :lines="lines" :running="running" />
    </template>
  </Card>
</template>

<style scoped>
.progress-header {
  display: flex;
  align-items: center;
  gap: 0.75rem;
}

.running-text {
  font-size: 0.875rem;
  color: var(--p-primary-color);
}
</style>
