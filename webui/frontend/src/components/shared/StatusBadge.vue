<script setup lang="ts">
import { computed } from 'vue'
import Tag from 'primevue/tag'

const props = defineProps<{
  status: string
}>()

const severity = computed(() => {
  switch (props.status) {
    case 'online':
    case 'running':
    case 'success':
    case 'completed':
    case 'ja':
      return 'success'
    case 'offline':
    case 'stopped':
    case 'failed':
    case 'error':
      return 'danger'
    case 'pending':
    case 'reboot':
      return 'warn'
    default:
      return 'info'
  }
})

const label = computed(() => {
  const labels: Record<string, string> = {
    online: 'Online',
    offline: 'Offline',
    running: 'Laufend',
    stopped: 'Gestoppt',
    completed: 'Abgeschlossen',
    failed: 'Fehlgeschlagen',
    pending: 'Wartend',
    success: 'Erfolgreich',
    error: 'Fehler',
    ja: 'Ja',
    nein: 'Nein',
  }
  return labels[props.status] || props.status
})
</script>

<template>
  <Tag :value="label" :severity="severity" rounded />
</template>
