import { spawn } from "node:child_process"

const HOOK = `${process.env.HOME}/.claude/hooks/ai-memory-save.sh`
const TURN_ENDED = new Set(["session.execution.succeeded", "session.execution.failed", "session.execution.interrupted"])

// Detached so the save survives OpenCode shutting down its server right after a turn (opencode run does)
const runHook = (...args) => spawn(HOOK, args, { detached: true, stdio: "ignore" }).unref()

export default {
  id: "ai-memory",
  async setup(ctx) {
    // OpenCode may probe setup() without a context during startup
    if (!ctx?.event?.subscribe || !ctx?.command?.transform) return

    await ctx.command.transform((editor) => {
      editor.add({
        name: "save-memory",
        description: "Save this session to the shared AI memory now",
        execute: async ({ sessionID }) => {
          runHook("opencode-save", sessionID)
          await ctx.session.synthetic({ sessionID, text: "Saving this session to ai-memory in the background" })
        },
      })
    })

    const controller = new AbortController()
    void (async () => {
      for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
        if (TURN_ENDED.has(event.type) && event.data?.sessionID) runHook("opencode-idle", event.data.sessionID)
      }
    })().catch(() => {})
    return () => controller.abort()
  },
}
