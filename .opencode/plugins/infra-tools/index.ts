import { spawn } from "node:child_process"
import { Plugin } from "@opencode/plugin"

/**
 * Project-local OpenCode tools for this Terraform repository.
 *
 * Everything here is read-only with respect to Azure:
 * - validate and plan never apply;
 * - status and run-command inspection only read state.
 *
 * There is deliberately no apply, destroy, or password-printing tool.
 */

const MAX_OUTPUT = 40_000
const VALIDATE_TIMEOUT_MS = 20 * 60 * 1000
const PLAN_TIMEOUT_MS = 20 * 60 * 1000
const STATUS_TIMEOUT_MS = 5 * 60 * 1000

interface CommandResult {
  code: number
  output: string
  timedOut: boolean
}

function run(command: string, args: string[], cwd: string, timeoutMs: number): Promise<CommandResult> {
  return new Promise((resolve) => {
    let settled = false
    let output = ""
    let timedOut = false

    const finish = (result: CommandResult) => {
      if (settled) return
      settled = true
      resolve(result)
    }

    const child = spawn(command, args, {
      cwd,
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"],
    })

    child.stdout.on("data", (chunk: Buffer) => {
      output += chunk.toString()
      if (output.length > MAX_OUTPUT * 2) output = output.slice(-MAX_OUTPUT)
    })

    child.stderr.on("data", (chunk: Buffer) => {
      output += chunk.toString()
      if (output.length > MAX_OUTPUT * 2) output = output.slice(-MAX_OUTPUT)
    })

    const timer = setTimeout(() => {
      timedOut = true
      child.kill("SIGKILL")
    }, timeoutMs)

    child.on("error", (error: Error) => {
      clearTimeout(timer)
      finish({ code: -1, output: `${output}\n${error.message}`.trim(), timedOut })
    })

    child.on("close", (code: number | null) => {
      clearTimeout(timer)
      finish({ code: code ?? -1, output: output.slice(-MAX_OUTPUT), timedOut })
    })
  })
}

function render(title: string, result: CommandResult): string {
  const status = result.timedOut ? "timed out and was killed" : `exit ${result.code}`
  const body = result.output.trim() || "(no output)"
  return `${title} — ${status}\n\n\`\`\`\n${body}\n\`\`\``
}

const NO_INPUT = {
  type: "object",
  properties: {},
  additionalProperties: false,
} as const

export default Plugin.define({
  id: "infra-tools",

  async setup(ctx) {
    const cwd = ctx.location.directory

    await ctx.tool.transform((editor) => {      editor.add({
        name: "infra_validate",
        description:
          "Run `make validate` in this repository: terraform init/fmt/validate, shellcheck, PSScriptAnalyzer on scripts and Terraform heredocs, tflint, tfsec, and git diff --check. Never applies. Reports the last 40k characters of output.",
        input: NO_INPUT,
        options: { codemode: true },
        execute: async () => {
          const result = await run("make", ["validate"], cwd, VALIDATE_TIMEOUT_MS)
          return { content: render("`make validate`", result) }
        },
      })

      editor.add({
        name: "infra_plan",
        description:
          "Run `./terraform-with-secrets.sh plan -no-color`. Injects TF_VAR_github_token from gh when needed. Read-only: it never applies or destroys. Use before summarizing proposed changes.",
        input: NO_INPUT,
        options: { codemode: true },
        execute: async () => {
          const result = await run(
            "./terraform-with-secrets.sh",
            ["plan", "-no-color"],
            cwd,
            PLAN_TIMEOUT_MS,
          )
          return { content: render("`./terraform-with-secrets.sh plan -no-color`", result) }
        },
      })

      editor.add({
        name: "infra_status",
        description:
          "Show Azure VM power and provisioning state via `make status`, plus the public IP via `make ip`. Read-only.",
        input: NO_INPUT,
        options: { codemode: true },
        execute: async () => {
          const status = await run("make", ["status"], cwd, STATUS_TIMEOUT_MS)
          const ip = await run("make", ["ip"], cwd, STATUS_TIMEOUT_MS)
          return {
            content: [render("`make status`", status), render("`make ip`", ip)].join("\n\n"),
          }
        },
      })

      editor.add({
        name: "infra_run_commands",
        description:
          "Show the execution state and output of every Azure VM run command via `make run-commands`, including enable-remote-management. Read-only: does not invoke or retry run commands.",
        input: NO_INPUT,
        options: { codemode: true },
        execute: async () => {
          const result = await run("make", ["run-commands"], cwd, STATUS_TIMEOUT_MS)
          return { content: render("`make run-commands`", result) }
        },
      })
    })
  },
})
