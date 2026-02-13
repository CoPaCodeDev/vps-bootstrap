<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useApi } from '@/composables/useApi'
import TemplateCard from '@/components/deploy/TemplateCard.vue'
import Button from 'primevue/button'

const { get, loading } = useApi()
const templates = ref<any[]>([])

onMounted(() => fetchTemplates())

async function fetchTemplates() {
  templates.value = await get<any[]>('/deploy/templates')
}
</script>

<template>
  <div>
    <div class="page-header">
      <h1>Deployments</h1>
      <Button label="Aktualisieren" icon="pi pi-refresh" text @click="fetchTemplates" :loading="loading" />
    </div>

    <div v-if="loading && templates.length === 0" class="loading">
      <i class="pi pi-spin pi-spinner" style="font-size: 2rem"></i>
    </div>

    <div v-else-if="templates.length === 0" class="empty-state">
      <i class="pi pi-cloud-upload" style="font-size: 3rem; color: var(--p-text-muted-color)"></i>
      <h3>Keine Templates verfügbar</h3>
      <p>Templates befinden sich in /opt/vps/templates/</p>
    </div>

    <div v-else class="template-grid">
      <TemplateCard
        v-for="tpl in templates"
        :key="tpl.name"
        :template="tpl"
      />
    </div>
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

.template-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
  gap: 1rem;
}

.loading, .empty-state {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  padding: 4rem 2rem;
  gap: 1rem;
  color: var(--p-text-muted-color);
}

.empty-state h3 {
  color: var(--p-text-color);
}
</style>
