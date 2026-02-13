<script setup lang="ts">
import Card from 'primevue/card'
import Button from 'primevue/button'
import Tag from 'primevue/tag'
import { useRouter } from 'vue-router'

const props = defineProps<{
  template: {
    name: string
    description: string
    has_authelia: boolean
    variables: any[]
    profiles: string[]
  }
}>()

const router = useRouter()

function startDeploy() {
  router.push({ name: 'deploy-wizard', params: { template: props.template.name } })
}
</script>

<template>
  <Card class="template-card">
    <template #header>
      <div class="card-header">
        <h3>{{ template.name }}</h3>
        <Tag v-if="template.has_authelia" value="Authelia" severity="info" rounded />
      </div>
    </template>
    <template #content>
      <p class="description">{{ template.description }}</p>
      <div class="meta">
        <span>{{ template.variables.length }} Variablen</span>
        <span v-if="template.profiles.length">Profile: {{ template.profiles.join(', ') }}</span>
      </div>
    </template>
    <template #footer>
      <Button label="Deployen" icon="pi pi-cloud-upload" size="small" @click="startDeploy" />
    </template>
  </Card>
</template>

<style scoped>
.template-card {
  height: 100%;
  display: flex;
  flex-direction: column;
}

.card-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 1rem 1.25rem 0;
}

.card-header h3 {
  font-size: 1rem;
  font-weight: 600;
}

.description {
  font-size: 0.875rem;
  color: var(--p-text-muted-color);
  margin-bottom: 0.75rem;
}

.meta {
  display: flex;
  gap: 1rem;
  font-size: 0.75rem;
  color: var(--p-text-muted-color);
}
</style>
