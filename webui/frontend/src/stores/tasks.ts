import { defineStore } from 'pinia'
import { ref } from 'vue'
import { useApi } from '@/composables/useApi'

export interface TaskInfo {
  task_id: string
  type: string
  description: string
  status: string
  host: string
  started_at: string
  finished_at: string
  exit_code: number | null
  output_lines: number
}

export const useTasksStore = defineStore('tasks', () => {
  const tasks = ref<TaskInfo[]>([])
  const loading = ref(false)

  const api = useApi()

  async function fetchTasks() {
    loading.value = true
    try {
      tasks.value = await api.get<TaskInfo[]>('/tasks/')
    } finally {
      loading.value = false
    }
  }

  function activeTasks() {
    return tasks.value.filter((t) => t.status === 'running' || t.status === 'pending')
  }

  return { tasks, loading, fetchTasks, activeTasks }
})
