<script setup lang="ts">
import { ref } from 'vue'
import Dialog from 'primevue/dialog'
import InputText from 'primevue/inputtext'
import Button from 'primevue/button'

const props = defineProps<{
  visible: boolean
  snapshotId: string
  host: string
}>()

const emit = defineEmits<{
  'update:visible': [value: boolean]
  confirm: [data: { snapshot_id: string; target: string; paths: string[] }]
}>()

const target = ref('/')
const paths = ref('')

function doRestore() {
  const pathList = paths.value
    ? paths.value.split(',').map((p) => p.trim()).filter(Boolean)
    : []

  emit('confirm', {
    snapshot_id: props.snapshotId,
    target: target.value,
    paths: pathList,
  })
  emit('update:visible', false)
}
</script>

<template>
  <Dialog
    :visible="visible"
    @update:visible="emit('update:visible', $event)"
    header="Backup wiederherstellen"
    :modal="true"
    :style="{ width: '30rem' }"
  >
    <div class="form">
      <div class="field">
        <label>Snapshot</label>
        <code>{{ snapshotId }}</code>
      </div>
      <div class="field">
        <label>Zielverzeichnis</label>
        <InputText v-model="target" placeholder="/" class="w-full" />
      </div>
      <div class="field">
        <label>Pfade (kommagetrennt, leer = alle)</label>
        <InputText v-model="paths" placeholder="/opt/app, /etc/config" class="w-full" />
      </div>
    </div>
    <template #footer>
      <Button label="Abbrechen" text @click="emit('update:visible', false)" />
      <Button label="Wiederherstellen" icon="pi pi-history" severity="warn" @click="doRestore" />
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
