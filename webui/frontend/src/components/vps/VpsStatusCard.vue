<script setup lang="ts">
import { computed } from 'vue'
import { useRouter } from 'vue-router'
import Card from 'primevue/card'
import VpsStatusBadge from './VpsStatusBadge.vue'
import type { VPS, VPSStatus } from '@/stores/vps'

const props = defineProps<{
  vps: VPS
  status?: VPSStatus
}>()

const router = useRouter()

const online = computed(() => props.status?.online ?? false)

function goToDetail() {
  router.push({ name: 'vps-detail', params: { host: props.vps.name } })
}
</script>

<template>
  <Card class="vps-card" @click="goToDetail">
    <template #header>
      <div class="card-header">
        <div class="card-title">
          <h3>{{ vps.name }}</h3>
          <span class="ip-label">{{ vps.ip }}</span>
        </div>
        <VpsStatusBadge :online="online" />
      </div>
    </template>
    <template #content>
      <div v-if="status && online" class="stats">
        <div class="stat">
          <span class="stat-label">Load</span>
          <span class="stat-value">{{ status.load || '-' }}</span>
        </div>
        <div class="stat">
          <span class="stat-label">Updates</span>
          <span class="stat-value" :class="{ warn: status.updates_available > 0 }">
            {{ status.updates_available }}
          </span>
        </div>
        <div class="stat">
          <span class="stat-label">RAM</span>
          <span class="stat-value">{{ status.memory_used || '-' }} / {{ status.memory_total || '-' }}</span>
        </div>
        <div class="stat">
          <span class="stat-label">Disk</span>
          <span class="stat-value">{{ status.disk_used || '-' }} / {{ status.disk_total || '-' }}</span>
        </div>
      </div>
      <div v-else-if="!status" class="loading-stats">
        <i class="pi pi-spin pi-spinner"></i> Lade Status...
      </div>
      <div v-else class="offline-msg">
        Nicht erreichbar
      </div>
      <div v-if="status?.reboot_required" class="reboot-warning">
        <i class="pi pi-exclamation-triangle"></i> Neustart erforderlich
      </div>
    </template>
  </Card>
</template>

<style scoped>
.vps-card {
  cursor: pointer;
  transition: all 0.15s;
}

.vps-card:hover {
  transform: translateY(-2px);
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.1);
}

.card-header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  padding: 1rem 1.25rem 0;
}

.card-title h3 {
  font-size: 1rem;
  font-weight: 600;
  margin-bottom: 0.25rem;
}

.ip-label {
  font-size: 0.75rem;
  color: var(--p-text-muted-color);
  font-family: monospace;
}

.stats {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.75rem;
}

.stat {
  display: flex;
  flex-direction: column;
  gap: 0.125rem;
}

.stat-label {
  font-size: 0.7rem;
  text-transform: uppercase;
  color: var(--p-text-muted-color);
  letter-spacing: 0.05em;
}

.stat-value {
  font-size: 0.875rem;
  font-weight: 500;
}

.stat-value.warn {
  color: var(--p-orange-500);
}

.loading-stats {
  color: var(--p-text-muted-color);
  font-size: 0.875rem;
}

.offline-msg {
  color: var(--p-text-muted-color);
  font-size: 0.875rem;
  font-style: italic;
}

.reboot-warning {
  margin-top: 0.75rem;
  padding: 0.375rem 0.5rem;
  background: var(--p-orange-50);
  color: var(--p-orange-700);
  border-radius: var(--p-border-radius);
  font-size: 0.75rem;
  display: flex;
  align-items: center;
  gap: 0.375rem;
}
</style>
