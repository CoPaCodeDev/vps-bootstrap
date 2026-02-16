<script setup lang="ts">
import { ref, computed, watch } from 'vue'
import Dialog from 'primevue/dialog'
import InputText from 'primevue/inputtext'
import Password from 'primevue/password'
import Select from 'primevue/select'
import Checkbox from 'primevue/checkbox'
import Button from 'primevue/button'
import Message from 'primevue/message'
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
const password = ref('')
const passwordConfirm = ref('')
const setupVlan = ref(true)
const vlanIp = ref('')
const images = ref<any[]>([])
const selectedImage = ref<any>(null)
const loadingImages = ref(false)

const passwordErrors = computed(() => {
  const errors: string[] = []
  if (!password.value) return errors
  if (password.value.length < 8) errors.push('Min. 8 Zeichen')
  if (!/[A-Z]/.test(password.value)) errors.push('Großbuchstabe fehlt')
  if (!/[a-z]/.test(password.value)) errors.push('Kleinbuchstabe fehlt')
  if (!/[0-9]/.test(password.value)) errors.push('Zahl fehlt')
  return errors
})

const passwordMismatch = computed(() => {
  return passwordConfirm.value !== '' && password.value !== passwordConfirm.value
})

const formValid = computed(() => {
  return (
    hostname.value.trim() !== '' &&
    selectedImage.value !== null &&
    password.value !== '' &&
    passwordErrors.value.length === 0 &&
    password.value === passwordConfirm.value
  )
})

watch(() => props.visible, async (open) => {
  if (!open) return
  hostname.value = props.initialHostname || ''
  password.value = ''
  passwordConfirm.value = ''
  setupVlan.value = true
  vlanIp.value = ''
  selectedImage.value = null
  images.value = []
  loadingImages.value = true
  try {
    const [raw, nextIp] = await Promise.all([
      get<any[]>(`/netcup/servers/${props.serverId}/images`),
      get<{ ip: string }>('/netcup/vlan/next-ip'),
    ])
    vlanIp.value = nextIp.ip
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
  if (!formValid.value) return
  try {
    await task.startTask(`/netcup/servers/${props.serverId}/install`, {
      hostname: hostname.value,
      image: selectedImage.value.image?.name || selectedImage.value.name,
      password: password.value,
      setup_vlan: setupVlan.value,
      vlan_ip: setupVlan.value ? vlanIp.value : '',
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
      <Message severity="warn" :closable="false">
        Alle Daten auf diesem Server werden gelöscht!
      </Message>

      <div class="field">
        <label>Server-ID</label>
        <code>{{ serverId }}</code>
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

      <div class="field">
        <label>Hostname</label>
        <InputText v-model="hostname" placeholder="mein-vps" class="w-full" />
      </div>

      <div class="field">
        <label>Passwort</label>
        <Password
          v-model="password"
          placeholder="Passwort für User 'master'"
          :feedback="false"
          toggleMask
          class="w-full"
          inputClass="w-full"
        />
        <small v-if="passwordErrors.length > 0" class="p-error">
          {{ passwordErrors.join(', ') }}
        </small>
      </div>

      <div class="field">
        <label>Passwort bestätigen</label>
        <Password
          v-model="passwordConfirm"
          placeholder="Passwort wiederholen"
          :feedback="false"
          toggleMask
          class="w-full"
          inputClass="w-full"
        />
        <small v-if="passwordMismatch" class="p-error">
          Passwörter stimmen nicht überein
        </small>
      </div>

      <div class="field-checkbox">
        <Checkbox v-model="setupVlan" :binary="true" inputId="setupVlan" />
        <label for="setupVlan">CloudVLAN einrichten</label>
      </div>

      <div v-if="setupVlan" class="field">
        <label>CloudVLAN-IP</label>
        <InputText v-model="vlanIp" placeholder="10.10.0.x" class="w-full" />
        <small>Nächste freie IP vorausgewählt</small>
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
        :disabled="!formValid"
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

.field-checkbox {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.field-checkbox label {
  font-size: 0.875rem;
  font-weight: 500;
}

.w-full {
  width: 100%;
}

.p-error {
  color: var(--p-red-500);
}
</style>
