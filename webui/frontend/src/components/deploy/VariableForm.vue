<script setup lang="ts">
import { computed } from 'vue'
import InputText from 'primevue/inputtext'
import Password from 'primevue/password'

interface TemplateVariable {
  name: string
  type: string
  default: string
  description: string
  condition: string
}

const props = defineProps<{
  variables: TemplateVariable[]
  modelValue: Record<string, string>
}>()

const emit = defineEmits<{
  'update:modelValue': [value: Record<string, string>]
}>()

const visibleVars = computed(() => {
  return props.variables.filter((v) => {
    if (!v.condition) return true
    // Parse "VAR=wert1,wert2"
    const [condVar, condValues] = v.condition.split('=')
    if (!condVar || !condValues) return true
    const allowed = condValues.split(',')
    return allowed.includes(props.modelValue[condVar] || '')
  })
})

function update(name: string, value: string) {
  emit('update:modelValue', { ...props.modelValue, [name]: value })
}
</script>

<template>
  <div class="var-form">
    <div v-for="v in visibleVars" :key="v.name" class="field">
      <label :for="v.name">{{ v.description || v.name }}</label>
      <small v-if="v.type === 'generate'" class="hint">Wird automatisch generiert</small>
      <Password
        v-if="v.type === 'secret'"
        :modelValue="modelValue[v.name] || ''"
        @update:modelValue="update(v.name, $event)"
        :placeholder="v.description"
        toggleMask
        class="w-full"
        :input-class="'w-full'"
      />
      <InputText
        v-else-if="v.type !== 'generate'"
        :modelValue="modelValue[v.name] || v.default || ''"
        @update:modelValue="update(v.name, $event)"
        :placeholder="v.default || v.description"
        class="w-full"
        :disabled="v.type === 'generate'"
      />
    </div>
  </div>
</template>

<style scoped>
.var-form {
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

.hint {
  font-size: 0.75rem;
  color: var(--p-text-muted-color);
  font-style: italic;
}

.w-full {
  width: 100%;
}
</style>
