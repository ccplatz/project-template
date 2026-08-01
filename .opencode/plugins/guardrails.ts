import type { Plugin } from "@opencode-ai/plugin"

const CHECK_SCRIPT = "./bin/guardrails-check"

const DANGEROUS_PATTERNS: Array<{ pattern: RegExp; explanation: string }> = [
    { pattern: /\brm\s+-rf\s+\//, explanation: "rm -rf / would wipe the entire filesystem" },
    { pattern: /\bchmod\s+777\s+\//, explanation: "chmod 777 / makes the entire filesystem world-writable" },
    { pattern: />\s*\/dev\/sda/, explanation: "Writing directly to /dev/sda can corrupt the disk" },
    { pattern: /\bcurl\b.*\b\|\s*(ba)?sh/, explanation: "Piping curl to shell is a security risk — verify the source first" },
    { pattern: /\bwget\b.*\b\|\s*(ba)?sh/, explanation: "Piping wget to shell is a security risk — verify the source first" },
]

async function runCheck(
    $: any,
    args: string[],
    directory: string,
): Promise<{ lines: string[]; exitCode: number }> {
    try {
        const cmd = [CHECK_SCRIPT, ...args]
        const result = await $({ cwd: directory })`${cmd}`.quiet()
        const text = result.stdout?.toString() || ""
        const lines = text
            .split("\n")
            .map((l: string) => l.trim())
            .filter(Boolean)
        return { lines, exitCode: result.exitCode }
    } catch (err: any) {
        return { lines: [], exitCode: err.exitCode ?? 127 }
    }
}

export const GuardrailsPlugin: Plugin = async ({ client, $, directory }) => {
    await client.app.log({
        body: {
            service: "guardrails",
            level: "info",
            message: "Guardrails plugin initialized",
        },
    })

    return {
        "file.edited": async (input: any) => {
            const filePath = input?.file || input?.path || ""
            if (!filePath) return

            if (
                filePath.includes("vendor/") ||
                filePath.includes("node_modules/") ||
                filePath.includes("storage/") ||
                filePath.includes(".git/")
            ) {
                return
            }

            if (
                !filePath.endsWith(".php") &&
                !filePath.endsWith(".ts") &&
                !filePath.endsWith(".tsx")
            ) {
                return
            }

            try {
                const result = await runCheck($, ["--warn", "--ci"], directory)
                const relevant = result.lines.filter((l) =>
                    l.startsWith(filePath + ":"),
                )

                if (relevant.length > 0) {
                    for (const violation of relevant) {
                        await client.app.log({
                            body: {
                                service: "guardrails",
                                level: "warn",
                                message: `Guardrails violation after editing ${filePath}`,
                                extra: { file: filePath, violation },
                            },
                        })
                    }
                }
            } catch {
                await client.app.log({
                    body: {
                        service: "guardrails",
                        level: "error",
                        message: `Failed to run guardrails check on ${filePath}`,
                    },
                })
            }
        },

        "tool.execute.before": async (input: any, output: any) => {
            if (input?.tool !== "bash") return
            const command: string = output?.args?.command || ""
            if (!command) return

            for (const { pattern, explanation } of DANGEROUS_PATTERNS) {
                if (pattern.test(command)) {
                    throw new Error(
                        `Blocked dangerous command: "${command}" — ${explanation}. ` +
                            "If you need to run this command, review and explicitly approve changes to the affected paths.",
                    )
                }
            }
        },

        "session.idle": async () => {
            try {
                const result = await runCheck($, ["--ci"], directory)

                if (result.lines.length > 0) {
                    await client.app.log({
                        body: {
                            service: "guardrails",
                            level: "warn",
                            message: `Guardrails violations detected at session end (${result.lines.length} issues)`,
                            extra: { violations: result.lines },
                        },
                    })
                }
            } catch {
                await client.app.log({
                    body: {
                        service: "guardrails",
                        level: "error",
                        message: "Failed to run guardrails check at session end",
                    },
                })
            }
        },
    }
}
