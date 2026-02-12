<script setup lang="ts">
import Card from 'primevue/card'
import StatusBadge from '@/components/shared/StatusBadge.vue'

defineProps<{
  status: {
    host: string
    last_backup: string
    next_backup: string
    snapshots: number
    repo_size: string
    healthy: boolean
  }
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
  <Card class="backup-card">
    <template #header>
      <div class="card-header">
        <h3>{{ status.host }}</h3>
        <StatusBadge :status="status.healthy ? 'online' : 'offline'" />
      </div>
    </template>
    <template #content>
      <div class="stats">
        <div class="stat">
          <span class="label">Letztes Backup</span>
          <span class="value">{{ formatTime(status.last_backup) }}</span>
        </div>
        <div class="stat">
          <span class="label">Snapshots</span>
          <span class="value">{{ status.snapshots }}</span>
        </div>
        <div class="stat">
          <span class="label">Repo-Größe</span>
          <span class="value">{{ status.repo_size || '-' }}</span>
        </div>
      </div>
    </template>
  </Card>
</template>

<style scoped>
.card-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 1rem 1.25rem 0;
}

.card-header h3 {
  font-size: 1rem;
  font-weight: 600;
}

.stats {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}

.stat {
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.label {
  font-size: 0.8125rem;
  color: var(--p-text-muted-color);
}

.value {
  font-size: 0.8125rem;
  font-weight: 500;
}
</style>
