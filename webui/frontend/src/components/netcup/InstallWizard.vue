<script setup lang="ts">
import { ref } from 'vue'
import Dialog from 'primevue/dialog'
import InputText from 'primevue/inputtext'
import Button from 'primevue/button'
import { useApi } from '@/composables/useApi'
import { useTaskStream } from '@/composables/useTaskStream'
import LiveTerminal from '@/components/shared/LiveTerminal.vue'
import { useToast } from 'primevue/usetoast'

const props = defineProps<{
  visible: boolean
  serverId: string
}>()

const emit = defineEmits<{
  'update:visible': [value: boolean]
}>()

const { post } = useApi()
const toast = useToast()
const task = useTaskStream()

const hostname = ref('')
const image = ref('Debian 13')

async function startInstall() {
  if (!hostname.value) return
  try {
    await task.startTask(`/netcup/servers/${props.serverId}/install`, {
      hostname: hostname.value,
      image: image.value,
    })
    toast.add({ severity: 'info', summary: 'Installation gestartet', life: 3000 })
  } catch (e: any) {
    toast.add({ severity: 'error', summary: 'Fehler', detail: e.detail, life: 3000 })
  }
}
</script>

<template>
  <Dialog
    :visible="visible"
    @update:visible="emit('update:visible', $event)"
    header="VPS installieren"
    :modal="true"
    :style="{ width: '40rem' }"
  >
    <div v-if="task.output.value.length === 0" class="form">
      <div class="field">
        <label>Server-ID</label>
        <code>{{ serverId }}</code>
      </div>
      <div class="field">
        <label>Hostname</label>
        <InputText v-model="hostname" placeholder="mein-vps" class="w-full" />
      </div>
      <div class="field">
        <label>Image</label>
        <InputText v-model="image" placeholder="Debian 13" class="w-full" />
      </div>
    </div>

    <LiveTerminal
      v-if="task.output.value.length > 0"
      :lines="task.output.value"
      :running="task.running.value"
    />

    <template #footer>
      <Button label="Abbrechen" text @click="emit('update:visible', false)" />
      <Button
        v-if="task.output.value.length === 0"
        label="Installieren"
        icon="pi pi-download"
        severity="warn"
        @click="startInstall"
        :disabled="!hostname"
      />
    </template>
  </Dialog>
</template>

<style scoped>
.form {
  display: flex;
  flex-direction: column;
  gap: 1rem;
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
