<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useApi } from '@/composables/useApi'
import UserTable from '@/components/authelia/UserTable.vue'
import DomainTable from '@/components/authelia/DomainTable.vue'
import StatusBadge from '@/components/shared/StatusBadge.vue'
import Card from 'primevue/card'
import Button from 'primevue/button'
import { useToast } from 'primevue/usetoast'

const { get, post, loading } = useApi()
const toast = useToast()

const status = ref<any>(null)
const users = ref<any[]>([])
const domains = ref<any[]>([])

onMounted(() => fetchAll())

async function fetchAll() {
  const [s, u, d] = await Promise.all([
    get<any>('/authelia/status'),
    get<any[]>('/authelia/users'),
    get<any[]>('/authelia/domains'),
  ])
  status.value = s
  users.value = u
  domains.value = d
}

async function restart() {
  try {
    await post('/authelia/restart')
    toast.add({ severity: 'success', summary: 'Authelia neu gestartet', life: 3000 })
    setTimeout(() => fetchAll(), 2000)
  } catch (e: any) {
    toast.add({ severity: 'error', summary: 'Fehler', detail: e.detail, life: 3000 })
  }
}
</script>

<template>
  <div>
    <div class="page-header">
      <h1>Authelia-Verwaltung</h1>
      <div class="actions">
        <Button label="Aktualisieren" icon="pi pi-refresh" text @click="fetchAll" :loading="loading" />
        <Button label="Neustarten" icon="pi pi-replay" severity="secondary" @click="restart" />
      </div>
    </div>

    <!-- Status -->
    <Card v-if="status" class="section">
      <template #content>
        <div class="status-row">
          <div class="status-item">
            <span class="label">Status</span>
            <StatusBadge :status="status.running ? 'running' : 'stopped'" />
          </div>
          <div class="status-item">
            <span class="label">Version</span>
            <span>{{ status.version || '-' }}</span>
          </div>
          <div class="status-item">
            <span class="label">Benutzer</span>
            <span>{{ status.users }}</span>
          </div>
          <div class="status-item">
            <span class="label">Domains</span>
            <span>{{ status.domains }}</span>
          </div>
        </div>
      </template>
    </Card>

    <!-- Benutzer -->
    <Card class="section">
      <template #content>
        <UserTable :users="users" :loading="loading" @refresh="fetchAll" />
      </template>
    </Card>

    <!-- Domains -->
    <Card class="section">
      <template #content>
        <DomainTable :domains="domains" :loading="loading" @refresh="fetchAll" />
      </template>
    </Card>
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

.section {
  margin-bottom: 1.5rem;
}

.status-row {
  display: flex;
  gap: 2rem;
  flex-wrap: wrap;
}

.status-item {
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}

.status-item .label {
  font-size: 0.7rem;
  text-transform: uppercase;
  color: var(--p-text-muted-color);
  letter-spacing: 0.05em;
}
</style>
