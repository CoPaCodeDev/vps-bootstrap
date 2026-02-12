<script setup lang="ts">
import { ref, watch } from 'vue'
import Dialog from 'primevue/dialog'
import InputText from 'primevue/inputtext'
import InputNumber from 'primevue/inputnumber'
import InputSwitch from 'primevue/inputswitch'
import Button from 'primevue/button'
import { useApi } from '@/composables/useApi'
import { useToast } from 'primevue/usetoast'

const props = defineProps<{
  visible: boolean
}>()

const emit = defineEmits<{
  'update:visible': [value: boolean]
  added: []
}>()

const { post, loading } = useApi()
const toast = useToast()

const domain = ref('')
const host = ref('')
const port = ref(8080)
const auth = ref(false)

watch(
  () => props.visible,
  (v) => {
    if (v) {
      domain.value = ''
      host.value = ''
      port.value = 8080
      auth.value = false
    }
  },
)

async function addRoute() {
  if (!domain.value || !host.value) return
  try {
    await post('/routes/', {
      domain: domain.value,
      host: host.value,
      port: port.value,
      auth: auth.value,
    })
    toast.add({ severity: 'success', summary: 'Route erstellt', detail: domain.value, life: 3000 })
    emit('update:visible', false)
    emit('added')
  } catch (e: any) {
    toast.add({ severity: 'error', summary: 'Fehler', detail: e.detail, life: 3000 })
  }
}
</script>

<template>
  <Dialog
    :visible="visible"
    @update:visible="emit('update:visible', $event)"
    header="Route hinzufügen"
    :modal="true"
    :style="{ width: '30rem' }"
  >
    <div class="form-grid">
      <div class="field">
        <label>Domain</label>
        <InputText v-model="domain" placeholder="app.example.de" class="w-full" />
      </div>
      <div class="field">
        <label>Ziel-Host (IP)</label>
        <InputText v-model="host" placeholder="10.10.0.x" class="w-full" />
      </div>
      <div class="field">
        <label>Port</label>
        <InputNumber v-model="port" :min="1" :max="65535" class="w-full" />
      </div>
      <div class="field-inline">
        <label>Authelia-Schutz</label>
        <InputSwitch v-model="auth" />
      </div>
    </div>
    <template #footer>
      <Button label="Abbrechen" text @click="emit('update:visible', false)" />
      <Button label="Erstellen" icon="pi pi-plus" @click="addRoute" :loading="loading" />
    </template>
  </Dialog>
</template>

<style scoped>
.form-grid {
  display: flex;
  flex-direction: column;
  gap: 1rem;
}

.field {
  display: flex;
  flex-direction: column;
  gap: 0.375rem;
}

.field label {
  font-size: 0.875rem;
  font-weight: 500;
}

.field-inline {
  display: flex;
  align-items: center;
  justify-content: space-between;
}

.field-inline label {
  font-size: 0.875rem;
  font-weight: 500;
}

.w-full {
  width: 100%;
}
</style>
