<script setup lang="ts">
import { ref } from 'vue'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import Dialog from 'primevue/dialog'
import InputText from 'primevue/inputtext'
import Password from 'primevue/password'
import Tag from 'primevue/tag'
import { useApi } from '@/composables/useApi'
import { useToast } from 'primevue/usetoast'

interface User {
  username: string
  displayname: string
  email: string
  groups: string[]
  disabled: boolean
}

const props = defineProps<{
  users: User[]
  loading?: boolean
}>()

const emit = defineEmits<{ refresh: [] }>()

const { post, del } = useApi()
const toast = useToast()

const showAdd = ref(false)
const newUser = ref({ username: '', displayname: '', email: '', password: '', groups: '' })
const adding = ref(false)

async function addUser() {
  if (!newUser.value.username || !newUser.value.password) return
  adding.value = true
  try {
    await post('/authelia/users', {
      username: newUser.value.username,
      displayname: newUser.value.displayname,
      email: newUser.value.email,
      password: newUser.value.password,
      groups: newUser.value.groups ? newUser.value.groups.split(',').map((g) => g.trim()) : [],
    })
    toast.add({ severity: 'success', summary: 'Benutzer erstellt', detail: newUser.value.username, life: 3000 })
    showAdd.value = false
    newUser.value = { username: '', displayname: '', email: '', password: '', groups: '' }
    emit('refresh')
  } catch (e: any) {
    toast.add({ severity: 'error', summary: 'Fehler', detail: e.detail, life: 3000 })
  } finally {
    adding.value = false
  }
}

async function removeUser(username: string) {
  try {
    await del(`/authelia/users/${username}`)
    toast.add({ severity: 'success', summary: 'Benutzer entfernt', detail: username, life: 3000 })
    emit('refresh')
  } catch (e: any) {
    toast.add({ severity: 'error', summary: 'Fehler', detail: e.detail, life: 3000 })
  }
}
</script>

<template>
  <div>
    <div class="table-header">
      <h3>Benutzer</h3>
      <Button label="Hinzufügen" icon="pi pi-plus" size="small" @click="showAdd = true" />
    </div>

    <DataTable :value="users" :loading="loading" stripedRows size="small">
      <Column field="username" header="Benutzername" sortable />
      <Column field="displayname" header="Anzeigename" />
      <Column field="email" header="E-Mail" />
      <Column field="groups" header="Gruppen">
        <template #body="{ data }">
          <Tag v-for="g in data.groups" :key="g" :value="g" severity="info" class="mr-1" />
        </template>
      </Column>
      <Column header="" style="width: 4rem">
        <template #body="{ data }">
          <Button
            icon="pi pi-trash"
            severity="danger"
            text
            size="small"
            @click="removeUser(data.username)"
            title="Entfernen"
          />
        </template>
      </Column>
      <template #empty>Keine Benutzer</template>
    </DataTable>

    <Dialog v-model:visible="showAdd" header="Benutzer hinzufügen" :modal="true" :style="{ width: '28rem' }">
      <div class="form">
        <div class="field">
          <label>Benutzername</label>
          <InputText v-model="newUser.username" class="w-full" />
        </div>
        <div class="field">
          <label>Anzeigename</label>
          <InputText v-model="newUser.displayname" class="w-full" />
        </div>
        <div class="field">
          <label>E-Mail</label>
          <InputText v-model="newUser.email" type="email" class="w-full" />
        </div>
        <div class="field">
          <label>Passwort</label>
          <Password v-model="newUser.password" toggleMask class="w-full" :input-class="'w-full'" />
        </div>
        <div class="field">
          <label>Gruppen (kommagetrennt)</label>
          <InputText v-model="newUser.groups" placeholder="admin, users" class="w-full" />
        </div>
      </div>
      <template #footer>
        <Button label="Abbrechen" text @click="showAdd = false" />
        <Button label="Erstellen" icon="pi pi-check" @click="addUser" :loading="adding" />
      </template>
    </Dialog>
  </div>
</template>

<style scoped>
.table-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 0.75rem;
}

.table-header h3 {
  font-size: 1rem;
  font-weight: 600;
}

.form {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
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

.mr-1 {
  margin-right: 0.25rem;
}
</style>
