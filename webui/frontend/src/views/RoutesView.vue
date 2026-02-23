<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useApi } from '@/composables/useApi'
import RouteTable from '@/components/routes/RouteTable.vue'
import RouteAddDialog from '@/components/routes/RouteAddDialog.vue'
import Button from 'primevue/button'
import { useMobile } from '@/composables/useMobile'

const { isMobile } = useMobile()
const { get, loading } = useApi()
const routes = ref<any[]>([])
const showAddDialog = ref(false)

onMounted(() => fetchRoutes())

async function fetchRoutes() {
  routes.value = await get<any[]>('/routes/')
}
</script>

<template>
  <div>
    <div class="page-header">
      <h1>Routen</h1>
      <div class="actions">
        <Button :label="isMobile ? undefined : 'Aktualisieren'" icon="pi pi-refresh" text @click="fetchRoutes" :loading="loading" />
        <Button :label="isMobile ? undefined : 'Route hinzufügen'" icon="pi pi-plus" @click="showAddDialog = true" />
      </div>
    </div>

    <RouteTable :routes="routes" :loading="loading" @refresh="fetchRoutes" />

    <RouteAddDialog v-model:visible="showAddDialog" @added="fetchRoutes" />
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
</style>
