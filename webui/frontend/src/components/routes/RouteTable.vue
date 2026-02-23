<script setup lang="ts">
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import InputSwitch from 'primevue/inputswitch'
import { useApi } from '@/composables/useApi'
import { useToast } from 'primevue/usetoast'
import { useMobile } from '@/composables/useMobile'
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
const { isMobile } = useMobile()
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
  <!-- Mobile: Card-Liste -->
  <div v-if="isMobile" class="route-cards">
    <div v-for="r in routes" :key="r.domain" class="route-card">
      <div class="card-main">
        <div class="card-domain">{{ r.domain }}</div>
        <div class="card-detail">{{ r.host }}:{{ r.port }}</div>
      </div>
      <div class="card-controls">
        <div class="card-badges">
          <i :class="r.tls ? 'pi pi-lock' : 'pi pi-lock-open'" :style="{ color: r.tls ? 'var(--p-green-500)' : 'var(--p-text-muted-color)' }"></i>
          <InputSwitch
            :modelValue="r.auth"
            @update:modelValue="toggleAuth(r)"
            :disabled="toggling === r.domain"
          />
        </div>
        <Button
          icon="pi pi-trash"
          severity="danger"
          text
          size="small"
          @click="removeRoute(r.domain)"
        />
      </div>
    </div>
    <div v-if="routes.length === 0" class="empty">Keine Routen konfiguriert</div>
  </div>

  <!-- Desktop: Tabelle -->
  <DataTable v-else :value="routes" :loading="loading" stripedRows>
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

<style scoped>
.route-cards {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}

.route-card {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 0.75rem;
  background: var(--p-surface-card);
  border: 1px solid var(--p-surface-border);
  border-radius: var(--p-border-radius);
}

.card-domain {
  font-weight: 600;
  font-size: 0.875rem;
  word-break: break-all;
}

.card-detail {
  font-size: 0.8rem;
  color: var(--p-text-muted-color);
  font-family: monospace;
}

.card-controls {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  flex-shrink: 0;
}

.card-badges {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.empty {
  text-align: center;
  padding: 1rem;
  color: var(--p-text-muted-color);
}
</style>
