<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useNetcupStore } from '@/stores/netcup'
import DeviceCodeLogin from '@/components/netcup/DeviceCodeLogin.vue'
import ServerTable from '@/components/netcup/ServerTable.vue'
import InstallWizard from '@/components/netcup/InstallWizard.vue'
import Button from 'primevue/button'
import { useMobile } from '@/composables/useMobile'

const { isMobile } = useMobile()
const store = useNetcupStore()
const showInstall = ref(false)
const installServerId = ref('')
const installHostname = ref('')

onMounted(() => {
  store.fetchServers()
})

function onLoggedIn() {
  store.fetchServers()
}

function startInstall(serverId: string, hostname: string) {
  installServerId.value = serverId
  installHostname.value = hostname
  showInstall.value = true
}
</script>

<template>
  <div>
    <div class="page-header">
      <h1>Netcup-Server</h1>
      <div class="actions">
        <Button
          v-if="store.loggedIn"
          :label="isMobile ? undefined : 'Aktualisieren'"
          icon="pi pi-refresh"
          text
          @click="store.fetchServers()"
          :loading="store.loading"
        />
        <Button
          v-if="store.loggedIn"
          :label="isMobile ? undefined : 'Abmelden'"
          icon="pi pi-sign-out"
          severity="secondary"
          text
          @click="store.logout()"
        />
      </div>
    </div>

    <DeviceCodeLogin v-if="!store.loggedIn" @logged-in="onLoggedIn" />

    <div v-else>
      <ServerTable
        :servers="store.servers"
        :loading="store.loading"
        @install="startInstall"
        @refresh="store.fetchServers()"
      />
    </div>

    <InstallWizard
      v-model:visible="showInstall"
      :server-id="installServerId"
      :initial-hostname="installHostname"
    />
  </div>
</template>

<style scoped>
.page-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 1.5rem;
}

.page-header h1 {
  font-size: 1.5rem;
  font-weight: 700;
}

.actions {
  display: flex;
  gap: 0.5rem;
}
</style>
