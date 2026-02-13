<script setup lang="ts">
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import InputSwitch from 'primevue/inputswitch'
import { useApi } from '@/composables/useApi'
import { useToast } from 'primevue/usetoast'
import { ref } from 'vue'

interface Route {
  domain: string
  host: string
  port: number
  auth: boolean
  tls: boolean
}

const props = defineProps<{
  routes: Route[]
  loading?: boolean
}>()

const emit = defineEmits<{
  refresh: []
}>()

const { post, del } = useApi()
const toast = useToast()
const toggling = ref<string | null>(null)

async function toggleAuth(route: Route) {
  toggling.value = route.domain
  try {
    if (route.auth) {
      await post(`/routes/${route.domain}/noauth`)
      toast.add({ severity: 'info', summary: 'Auth deaktiviert', detail: route.domain, life: 3000 })
    } else {
      await post(`/routes/${route.domain}/auth`)
      toast.add({ severity: 'success', summary: 'Auth aktiviert', detail: route.domain, life: 3000 })
    }
    emit('refresh')
  } catch (e: any) {
    toast.add({ severity: 'error', summary: 'Fehler', detail: e.detail, life: 3000 })
  } finally {
    toggling.value = null
  }
}

async function removeRoute(domain: string) {
  try {
    await del(`/routes/${domain}`)
    toast.add({ severity: 'success', summary: 'Entfernt', detail: `Route ${domain} gelöscht`, life: 3000 })
    emit('refresh')
  } catch (e: any) {
    toast.add({ severity: 'error', summary: 'Fehler', detail: e.detail, life: 3000 })
  }
}
</script>

<template>
  <DataTable :value="routes" :loading="loading" stripedRows>
    <Column field="domain" header="Domain" sortable />
    <Column field="host" header="Ziel-Host" sortable />
    <Column field="port" header="Port" style="width: 6rem" />
    <Column header="Auth" style="width: 6rem">
      <template #body="{ data }">
        <InputSwitch
          :modelValue="data.auth"
          @update:modelValue="toggleAuth(data)"
          :disabled="toggling === data.domain"
        />
      </template>
    </Column>
    <Column header="TLS" style="width: 4rem">
      <template #body="{ data }">
        <i :class="data.tls ? 'pi pi-lock' : 'pi pi-lock-open'" :style="{ color: data.tls ? 'var(--p-green-500)' : 'var(--p-text-muted-color)' }"></i>
      </template>
    </Column>
    <Column header="" style="width: 4rem">
      <template #body="{ data }">
        <Button
          icon="pi pi-trash"
          severity="danger"
          text
          size="small"
          @click="removeRoute(data.domain)"
          title="Route entfernen"
        />
      </template>
    </Column>
    <template #empty>Keine Routen konfiguriert</template>
  </DataTable>
</template>
