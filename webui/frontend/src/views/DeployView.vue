<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useApi } from '@/composables/useApi'
import { useToast } from 'primevue/usetoast'
import TemplateCard from '@/components/deploy/TemplateCard.vue'
import Button from 'primevue/button'
import Toast from 'primevue/toast'

const { get, post, loading } = useApi()
const toast = useToast()
const templates = ref<any[]>([])
const updating = ref(false)

onMounted(() => fetchTemplates())

async function fetchTemplates() {
  templates.value = await get<any[]>('/deploy/templates')
}

async function updateTemplates() {
  updating.value = true
  try {
    const result = await post<{ updated: boolean; output: string; new_templates: string[] }>('/system/update')
    if (result.updated) {
      const msg = result.new_templates.length > 0
        ? `Neue Templates: ${result.new_templates.join(', ')}`
        : 'Templates aktualisiert'
      toast.add({ severity: 'success', summary: 'Update erfolgreich', detail: msg, life: 5000 })
      await fetchTemplates()
    } else {
      toast.add({ severity: 'info', summary: 'Bereits aktuell', detail: 'Keine neuen Updates verfuegbar.', life: 3000 })
    }
  } catch (e: any) {
    toast.add({ severity: 'error', summary: 'Update fehlgeschlagen', detail: e.detail || 'Unbekannter Fehler', life: 5000 })
  } finally {
    updating.value = false
  }
}
</script>

<template>
  <div>
    <Toast />
    <div class="page-header">
      <h1>Deployments</h1>
      <div class="header-actions">
        <Button label="Templates aktualisieren" icon="pi pi-download" severity="secondary" outlined @click="updateTemplates" :loading="updating" />
        <Button icon="pi pi-refresh" text rounded @click="fetchTemplates" :loading="loading" />
      </div>
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

.header-actions {
  display: flex;
  gap: 0.5rem;
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
