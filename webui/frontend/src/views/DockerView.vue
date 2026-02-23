<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useApi } from '@/composables/useApi'
import Card from 'primevue/card'
import Button from 'primevue/button'
import Accordion from 'primevue/accordion'
import AccordionPanel from 'primevue/accordionpanel'
import AccordionHeader from 'primevue/accordionheader'
import AccordionContent from 'primevue/accordioncontent'
import ContainerList from '@/components/docker/ContainerList.vue'
import StatusBadge from '@/components/shared/StatusBadge.vue'
import { useToast } from 'primevue/usetoast'
import { useMobile } from '@/composables/useMobile'

const { isMobile } = useMobile()

interface DockerOverview {
  host: string
  online: boolean
  docker_installed: boolean
  containers: any[]
  running: number
  stopped: number
}

const { get, post, loading } = useApi()
const toast = useToast()
const overview = ref<DockerOverview[]>([])

onMounted(() => fetchOverview())

async function fetchOverview() {
  overview.value = await get<DockerOverview[]>('/docker/')
}

async function installDocker(host: string) {
  try {
    await post(`/docker/${host}/install`)
    toast.add({ severity: 'info', summary: 'Installation gestartet', detail: `Docker wird auf ${host} installiert`, life: 3000 })
  } catch (e: any) {
    toast.add({ severity: 'error', summary: 'Fehler', detail: e.detail, life: 3000 })
  }
}
</script>

<template>
  <div>
    <div class="page-header">
      <h1>Docker-Verwaltung</h1>
      <Button :label="isMobile ? undefined : 'Aktualisieren'" icon="pi pi-refresh" text @click="fetchOverview" :loading="loading" />
    </div>

    <div v-if="overview.length === 0 && !loading" class="empty-state">
      <p>Keine VPS gefunden</p>
    </div>

    <Accordion multiple>
      <AccordionPanel v-for="item in overview" :key="item.host" :value="item.host">
        <AccordionHeader>
          <div class="host-header">
            <span class="host-name">{{ item.host }}</span>
            <StatusBadge :status="item.online ? 'online' : 'offline'" />
            <span v-if="item.docker_installed" class="container-count">
              {{ item.running }} laufend / {{ item.stopped }} gestoppt
            </span>
            <span v-else-if="item.online" class="no-docker">Docker nicht installiert</span>
          </div>
        </AccordionHeader>
        <AccordionContent>
          <div v-if="!item.online" class="offline-msg">Host nicht erreichbar</div>
          <div v-else-if="!item.docker_installed">
            <p>Docker ist nicht installiert.</p>
            <Button
              label="Docker installieren"
              icon="pi pi-download"
              severity="secondary"
              size="small"
              @click="installDocker(item.host)"
              class="mt-2"
            />
          </div>
          <ContainerList
            v-else
            :containers="item.containers"
            :host="item.host"
            @refresh="fetchOverview"
          />
        </AccordionContent>
      </AccordionPanel>
    </Accordion>
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

.host-header {
  display: flex;
  align-items: center;
  gap: 0.75rem;
}

.host-name {
  font-weight: 600;
}

.container-count {
  font-size: 0.8125rem;
  color: var(--p-text-muted-color);
}

.no-docker {
  font-size: 0.8125rem;
  color: var(--p-orange-500);
}

.offline-msg {
  color: var(--p-text-muted-color);
  font-style: italic;
  padding: 1rem 0;
}

.empty-state {
  text-align: center;
  padding: 3rem;
  color: var(--p-text-muted-color);
}

.mt-2 {
  margin-top: 0.5rem;
}
</style>
