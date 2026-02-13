import { ref } from 'vue'
import { useApi } from './useApi'
import { useWebSocket } from './useWebSocket'

export function useTaskStream() {
  const taskId = ref<string | null>(null)
  const { post } = useApi()
  const output = ref<string[]>([])
  const running = ref(false)
  const taskStatus = ref<string>('')

  async function startTask(endpoint: string, body?: unknown) {
    running.value = true
    output.value = []
    taskStatus.value = ''

    const result = await post<{ task_id: string }>(endpoint, body)
    taskId.value = result.task_id

    // WebSocket verbinden
    const ws = useWebSocket(`/api/v1/tasks/ws/${result.task_id}`)
    ws.connect()

    // Output weiterleiten
    const interval = setInterval(() => {
      if (ws.messages.value.length > output.value.length) {
        output.value = [...ws.messages.value]
      }
      if (ws.finished.value) {
        taskStatus.value = ws.status.value
        running.value = false
        clearInterval(interval)
      }
    }, 100)

    return result.task_id
  }

  return { taskId, output, running, taskStatus, startTask }
}
