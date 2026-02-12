<script setup lang="ts">
import { ref } from 'vue'
import Button from 'primevue/button'
import { useApi } from '@/composables/useApi'
import { useToast } from 'primevue/usetoast'

const props = defineProps<{
  host: string
  container: string
  state: string
}>()

const emit = defineEmits<{ done: [] }>()

const { post } = useApi()
const toast = useToast()
const loading = ref(false)

async function startContainer() {
  loading.value = true
  try {
    await post(`/docker/${props.host}/${props.container}/start`)
    toast.add({ severity: 'success', summary: 'Gestartet', detail: `${props.container} läuft`, life: 3000 })
    emit('done')
  } catch (e: any) {
    toast.add({ severity: 'error', summary: 'Fehler', detail: e.detail, life: 3000 })
  } finally {
    loading.value = false
  }
}

async function stopContainer() {
  loading.value = true
  try {
    await post(`/docker/${props.host}/${props.container}/stop`)
    toast.add({ severity: 'success', summary: 'Gestoppt', detail: `${props.container} gestoppt`, life: 3000 })
    emit('done')
  } catch (e: any) {
    toast.add({ severity: 'error', summary: 'Fehler', detail: e.detail, life: 3000 })
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <div class="actions">
    <Button
      v-if="state !== 'running'"
      icon="pi pi-play"
      severity="success"
      text
      size="small"
      @click="startContainer"
      :loading="loading"
      title="Starten"
    />
    <Button
      v-if="state === 'running'"
      icon="pi pi-stop"
      severity="danger"
      text
      size="small"
      @click="stopContainer"
      :loading="loading"
      title="Stoppen"
    />
  </div>
</template>

<style scoped>
.actions {
  display: flex;
  gap: 0.25rem;
}
</style>
