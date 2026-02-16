<script setup lang="ts">
import { ref, watch } from 'vue'
import Dialog from 'primevue/dialog'
import InputText from 'primevue/inputtext'
import Select from 'primevue/select'
import Button from 'primevue/button'
import { useApi } from '@/composables/useApi'
import { useTaskStream } from '@/composables/useTaskStream'
import LiveTerminal from '@/components/shared/LiveTerminal.vue'
import { useToast } from 'primevue/usetoast'

const props = defineProps<{
  visible: boolean
  serverId: string
  initialHostname?: string
}>()

const emit = defineEmits<{
  'update:visible': [value: boolean]
}>()

const { get, post } = useApi()
const toast = useToast()
const task = useTaskStream()

const hostname = ref('')
const images = ref<any[]>([])
const selectedImage = ref<any>(null)
const loadingImages = ref(false)

watch(() => props.visible, async (open) => {
  if (!open) return
  hostname.value = props.initialHostname || ''
  selectedImage.value = null
  images.value = []
  loadingImages.value = true
  try {
    const raw = await get<any[]>(`/netcup/servers/${props.serverId}/images`)
    images.value = raw.map(img => ({
      ...img,
      label: img.image?.name
        ? `${img.image.name} (${img.name})`
        : img.name,
    }))
    const debian = images.value.find(img =>
      img.label?.toLowerCase().includes('debian')
    )
    selectedImage.value = debian || images.value[0] || null
  } catch {
    toast.add({ severity: 'error', summary: 'Fehler', detail: 'Images konnten nicht geladen werden', life: 3000 })
  } finally {
    loadingImages.value = false
  }
})

async function startInstall() {
  if (!hostname.value || !selectedImage.value) return
  try {
    await task.startTask(`/netcup/servers/${props.serverId}/install`, {
      hostname: hostname.value,
      image: selectedImage.value.image?.name || selectedImage.value.name,
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
        <Select
          v-model="selectedImage"
          :options="images"
          optionLabel="label"
          placeholder="Image auswählen..."
          :loading="loadingImages"
          class="w-full"
        />
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
        :disabled="!hostname || !selectedImage"
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
