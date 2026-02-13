<script setup lang="ts">
import { ref } from 'vue'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import Dialog from 'primevue/dialog'
import InputText from 'primevue/inputtext'
import { useApi } from '@/composables/useApi'
import { useToast } from 'primevue/usetoast'

interface Domain {
  domain: string
  default_redirection_url: string
}

defineProps<{
  domains: Domain[]
  loading?: boolean
}>()

const emit = defineEmits<{ refresh: [] }>()

const { post, del } = useApi()
const toast = useToast()

const showAdd = ref(false)
const newDomain = ref('')
const adding = ref(false)

async function addDomain() {
  if (!newDomain.value) return
  adding.value = true
  try {
    await post('/authelia/domains', { domain: newDomain.value })
    toast.add({ severity: 'success', summary: 'Domain hinzugefügt', detail: newDomain.value, life: 3000 })
    showAdd.value = false
    newDomain.value = ''
    emit('refresh')
  } catch (e: any) {
    toast.add({ severity: 'error', summary: 'Fehler', detail: e.detail, life: 3000 })
  } finally {
    adding.value = false
  }
}

async function removeDomain(domain: string) {
  try {
    await del(`/authelia/domains/${domain}`)
    toast.add({ severity: 'success', summary: 'Domain entfernt', detail: domain, life: 3000 })
    emit('refresh')
  } catch (e: any) {
    toast.add({ severity: 'error', summary: 'Fehler', detail: e.detail, life: 3000 })
  }
}
</script>

<template>
  <div>
    <div class="table-header">
      <h3>Cookie-Domains</h3>
      <Button label="Hinzufügen" icon="pi pi-plus" size="small" @click="showAdd = true" />
    </div>

    <DataTable :value="domains" :loading="loading" stripedRows size="small">
      <Column field="domain" header="Domain" sortable />
      <Column field="default_redirection_url" header="Redirect-URL" />
      <Column header="" style="width: 4rem">
        <template #body="{ data }">
          <Button
            icon="pi pi-trash"
            severity="danger"
            text
            size="small"
            @click="removeDomain(data.domain)"
            title="Entfernen"
          />
        </template>
      </Column>
      <template #empty>Keine Domains konfiguriert</template>
    </DataTable>

    <Dialog v-model:visible="showAdd" header="Domain hinzufügen" :modal="true" :style="{ width: '28rem' }">
      <div class="field">
        <label>Domain</label>
        <InputText v-model="newDomain" placeholder="example.de" class="w-full" />
      </div>
      <template #footer>
        <Button label="Abbrechen" text @click="showAdd = false" />
        <Button label="Hinzufügen" icon="pi pi-plus" @click="addDomain" :loading="adding" />
      </template>
    </Dialog>
  </div>
</template>

<style scoped>
.table-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 0.75rem;
}

.table-header h3 {
  font-size: 1rem;
  font-weight: 600;
}

.field {
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}

.field label {
  font-size: 0.875rem;
  font-weight: 500;
}

.w-full {
  width: 100%;
}
</style>
