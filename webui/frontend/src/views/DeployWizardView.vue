<script setup lang="ts">
import { ref, onMounted, computed } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useApi } from '@/composables/useApi'
import { useVpsStore } from '@/stores/vps'
import { useTaskStream } from '@/composables/useTaskStream'
import VariableForm from '@/components/deploy/VariableForm.vue'
import DeployProgress from '@/components/deploy/DeployProgress.vue'
import Card from 'primevue/card'
import Button from 'primevue/button'
import Select from 'primevue/select'
import InputSwitch from 'primevue/inputswitch'
import Stepper from 'primevue/stepper'
import StepList from 'primevue/steplist'
import StepPanels from 'primevue/steppanels'
import Step from 'primevue/step'
import StepPanel from 'primevue/steppanel'
import { useToast } from 'primevue/usetoast'

const route = useRoute()
const router = useRouter()
const templateName = computed(() => route.params.template as string)
const { get } = useApi()
const vpsStore = useVpsStore()
const toast = useToast()
const task = useTaskStream()

const template = ref<any>(null)
const selectedHost = ref('')
const vars = ref<Record<string, string>>({})
const authEnabled = ref(false)

onMounted(async () => {
  await vpsStore.fetchHosts()
  template.value = await get<any>(`/deploy/templates/${templateName.value}`)
  // Default-Werte setzen
  if (template.value?.variables) {
    for (const v of template.value.variables) {
      if (v.default) {
        vars.value[v.name] = v.default
      }
    }
  }
})

const hostOptions = computed(() =>
  vpsStore.hosts.map((h) => ({ label: `${h.name} (${h.ip})`, value: h.name })),
)

async function deploy() {
  if (!selectedHost.value || !template.value) return
  try {
    await task.startTask('/deploy/', {
      template: templateName.value,
      host: selectedHost.value,
      vars: vars.value,
      auth: authEnabled.value,
    })
    toast.add({ severity: 'info', summary: 'Deployment gestartet', life: 3000 })
  } catch (e: any) {
    toast.add({ severity: 'error', summary: 'Fehler', detail: e.detail, life: 3000 })
  }
}
</script>

<template>
  <div>
    <div class="page-header">
      <div>
        <Button icon="pi pi-arrow-left" text @click="router.push('/deploy')" />
        <h1>{{ template?.name || templateName }}</h1>
      </div>
    </div>

    <p v-if="template?.description" class="description">{{ template.description }}</p>

    <div v-if="task.output.value.length > 0" class="deploy-output">
      <DeployProgress
        :lines="task.output.value"
        :running="task.running.value"
        :status="task.taskStatus.value"
      />
    </div>

    <div v-else-if="template" class="wizard-content">
      <Card class="section">
        <template #title>1. Ziel-VPS wählen</template>
        <template #content>
          <Select
            v-model="selectedHost"
            :options="hostOptions"
            optionLabel="label"
            optionValue="value"
            placeholder="VPS auswählen..."
            class="w-full"
          />
        </template>
      </Card>

      <Card class="section">
        <template #title>2. Konfiguration</template>
        <template #content>
          <VariableForm
            :variables="template.variables"
            v-model="vars"
          />
        </template>
      </Card>

      <Card class="section">
        <template #title>3. Optionen</template>
        <template #content>
          <div class="option-row" v-if="template.has_authelia">
            <label>Authelia-Schutz aktivieren</label>
            <InputSwitch v-model="authEnabled" />
          </div>
        </template>
      </Card>

      <div class="deploy-actions">
        <Button
          label="Deployen"
          icon="pi pi-cloud-upload"
          size="large"
          @click="deploy"
          :disabled="!selectedHost"
        />
      </div>
    </div>

    <div v-else class="loading">
      <i class="pi pi-spin pi-spinner" style="font-size: 2rem"></i>
    </div>
  </div>
</template>

<style scoped>
.page-header {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  margin-bottom: 1rem;
}

.page-header > div {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.page-header h1 {
  font-size: 1.5rem;
  font-weight: 700;
}

.description {
  color: var(--p-text-muted-color);
  margin-bottom: 1.5rem;
}

.section {
  margin-bottom: 1rem;
}

.option-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
}

.option-row label {
  font-size: 0.875rem;
  font-weight: 500;
}

.deploy-actions {
  display: flex;
  justify-content: flex-end;
  margin-top: 1rem;
}

.deploy-output {
  margin-top: 1rem;
}

.w-full {
  width: 100%;
}

.loading {
  display: flex;
  justify-content: center;
  padding: 4rem;
}
</style>
