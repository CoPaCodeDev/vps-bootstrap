<script setup lang="ts">
import { onMounted, ref, onUnmounted } from 'vue'
import { useTasksStore, type TaskInfo } from '@/stores/tasks'
import DataTable from 'primevue/datatable'
import Column from 'primevue/column'
import Button from 'primevue/button'
import Dialog from 'primevue/dialog'
import StatusBadge from '@/components/shared/StatusBadge.vue'
import LiveTerminal from '@/components/shared/LiveTerminal.vue'
import { useApi } from '@/composables/useApi'
import { useWebSocket } from '@/composables/useWebSocket'
import { useMobile } from '@/composables/useMobile'

const { isMobile } = useMobile()
const tasksStore = useTasksStore()
const { get } = useApi()

const selectedTask = ref<TaskInfo | null>(null)
const showOutput = ref(false)
const taskOutput = ref<string[]>([])
let refreshInterval: number | null = null

onMounted(() => {
  tasksStore.fetchTasks()
  refreshInterval = window.setInterval(() => tasksStore.fetchTasks(), 5000)
})

onUnmounted(() => {
  if (refreshInterval) clearInterval(refreshInterval)
})

async function viewOutput(task: TaskInfo) {
  selectedTask.value = task
  showOutput.value = true
  taskOutput.value = []

  const result = await get<{ lines: string[] }>(`/tasks/${task.task_id}/output`)
  taskOutput.value = result.lines

  if (task.status === 'running' || task.status === 'pending') {
    const ws = useWebSocket(`/api/v1/tasks/ws/${task.task_id}`)
    ws.connect()
    const interval = setInterval(() => {
      if (ws.messages.value.length > 0) {
        taskOutput.value = [...ws.messages.value]
      }
      if (ws.finished.value) {
        clearInterval(interval)
      }
    }, 200)
  }
}

function formatTime(iso: string) {
  if (!iso) return '-'
  try {
    return new Date(iso).toLocaleString('de-DE')
  } catch {
    return iso
  }
}
</script>

<template>
  <div>
    <div class="page-header">
      <h1>Hintergrund-Tasks</h1>
      <Button
        :label="isMobile ? undefined : 'Aktualisieren'"
        icon="pi pi-refresh"
        text
        @click="tasksStore.fetchTasks()"
        :loading="tasksStore.loading"
      />
    </div>

    <!-- Mobile: Card-Liste -->
    <div v-if="isMobile" class="task-cards">
      <div v-for="t in tasksStore.tasks" :key="t.task_id" class="task-card" @click="viewOutput(t)">
        <div class="card-row">
          <strong>{{ t.description || t.type }}</strong>
          <StatusBadge :status="t.status" />
        </div>
        <div class="card-detail">
          <span v-if="t.host">{{ t.host }}</span>
          <span>{{ formatTime(t.started_at) }}</span>
        </div>
      </div>
      <div v-if="tasksStore.tasks.length === 0" class="empty">Keine Tasks vorhanden</div>
    </div>

    <!-- Desktop: Tabelle -->
    <DataTable
      v-else
      :value="tasksStore.tasks"
      :loading="tasksStore.loading"
      stripedRows
      :sortOrder="-1"
      sortField="started_at"
    >
      <Column field="task_id" header="ID" style="width: 6rem">
        <template #body="{ data }">
          <code>{{ data.task_id }}</code>
        </template>
      </Column>
      <Column field="type" header="Typ" />
      <Column field="description" header="Beschreibung" />
      <Column field="host" header="Host" />
      <Column field="status" header="Status">
        <template #body="{ data }">
          <StatusBadge :status="data.status" />
        </template>
      </Column>
      <Column field="started_at" header="Gestartet">
        <template #body="{ data }">
          {{ formatTime(data.started_at) }}
        </template>
      </Column>
      <Column header="Aktionen" style="width: 8rem">
        <template #body="{ data }">
          <Button
            icon="pi pi-eye"
            text
            size="small"
            @click="viewOutput(data)"
            title="Output anzeigen"
          />
        </template>
      </Column>
      <template #empty>Keine Tasks vorhanden</template>
    </DataTable>

    <!-- Output-Dialog -->
    <Dialog
      v-model:visible="showOutput"
      :header="`Task: ${selectedTask?.description || ''}`"
      :modal="true"
      :style="isMobile ? { width: '100%', maxHeight: '80vh' } : { width: '60rem', maxHeight: '80vh' }"
      :maximizable="isMobile"
    >
      <LiveTerminal
        :lines="taskOutput"
        :running="selectedTask?.status === 'running'"
      />
    </Dialog>
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

.task-cards {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}

.task-card {
  padding: 0.75rem;
  background: var(--p-surface-card);
  border: 1px solid var(--p-surface-border);
  border-radius: var(--p-border-radius);
  cursor: pointer;
  transition: background 0.15s;
}

.task-card:active {
  background: var(--p-surface-hover);
}

.card-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 0.25rem;
}

.card-detail {
  display: flex;
  gap: 1rem;
  font-size: 0.8rem;
  color: var(--p-text-muted-color);
}

.empty {
  text-align: center;
  padding: 2rem;
  color: var(--p-text-muted-color);
}
</style>
