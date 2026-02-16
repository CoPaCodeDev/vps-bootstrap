<script setup lang="ts">
import { ref, onUnmounted } from 'vue'
import { useNetcupStore } from '@/stores/netcup'
import Card from 'primevue/card'
import Button from 'primevue/button'

const store = useNetcupStore()
const verificationUri = ref('')
const userCode = ref('')
const polling = ref(false)
const errorMsg = ref('')
let pollInterval: number | null = null

const emit = defineEmits<{ loggedIn: [] }>()

function stopPolling() {
  polling.value = false
  if (pollInterval) {
    clearInterval(pollInterval)
    pollInterval = null
  }
}

async function startLogin() {
  errorMsg.value = ''
  verificationUri.value = ''
  const result = await store.startLogin()
  verificationUri.value = result.verification_uri
  userCode.value = result.user_code

  // Polling starten
  polling.value = true
  pollInterval = window.setInterval(async () => {
    try {
      const status = await store.checkLoginStatus()
      if (status === 'success') {
        stopPolling()
        emit('loggedIn')
      } else if (status === 'error') {
        stopPolling()
        errorMsg.value = 'Anmeldung fehlgeschlagen oder abgelaufen. Bitte erneut versuchen.'
      }
    } catch {
      stopPolling()
      errorMsg.value = 'Verbindungsfehler. Bitte erneut versuchen.'
    }
  }, 5000)
}

onUnmounted(() => {
  stopPolling()
})

function openVerification() {
  window.open(verificationUri.value, '_blank')
}
</script>

<template>
  <Card>
    <template #title>Bei Netcup anmelden</template>
    <template #content>
      <div v-if="!verificationUri">
        <p>Melde dich über den Netcup Device Code Flow an, um Server zu verwalten.</p>
        <Button
          label="Anmeldung starten"
          icon="pi pi-sign-in"
          @click="startLogin"
          class="mt"
        />
      </div>
      <div v-else class="login-flow">
        <p>Öffne den folgenden Link und gib den Code ein:</p>
        <div class="code-display">
          <code class="user-code">{{ userCode }}</code>
        </div>
        <Button
          :label="verificationUri"
          link
          @click="openVerification"
          class="uri-btn"
        />
        <p v-if="polling" class="polling-msg">
          <i class="pi pi-spin pi-spinner"></i>
          Warte auf Bestätigung...
        </p>
        <div v-if="errorMsg" class="error-msg">
          <p>{{ errorMsg }}</p>
          <Button
            label="Erneut versuchen"
            icon="pi pi-refresh"
            severity="secondary"
            @click="startLogin"
          />
        </div>
      </div>
    </template>
  </Card>
</template>

<style scoped>
.mt {
  margin-top: 1rem;
}

.login-flow {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
}

.code-display {
  text-align: center;
  padding: 1rem;
  background: var(--p-surface-ground);
  border-radius: var(--p-border-radius);
}

.user-code {
  font-size: 1.5rem;
  font-weight: 700;
  letter-spacing: 0.2em;
}

.uri-btn {
  text-align: center;
}

.polling-msg {
  color: var(--p-primary-color);
  font-size: 0.875rem;
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.error-msg {
  color: var(--p-red-500);
  font-size: 0.875rem;
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}
</style>
