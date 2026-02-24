import { describe, expect, it } from "vitest";
import { AssistantMessageComponent } from "./assistant-message.js";
import { ChatLog } from "./chat-log.js";

describe("ChatLog", () => {
  it("caps component growth to avoid unbounded render trees", () => {
    const chatLog = new ChatLog(20);
    for (let i = 1; i <= 40; i++) {
      chatLog.addSystem(`system-${i}`);
    }

    expect(chatLog.children.length).toBe(20);
    const rendered = chatLog.render(120).join("\n");
    expect(rendered).toContain("system-40");
    expect(rendered).not.toContain("system-1");
  });

  it("drops stale streaming references when old components are pruned", () => {
    const chatLog = new ChatLog(20);
    chatLog.startAssistant("first", "run-1");
    for (let i = 0; i < 25; i++) {
      chatLog.addSystem(`overflow-${i}`);
    }

    // Should not throw if the original streaming component was pruned.
    chatLog.updateAssistant("recreated", "run-1");

    const rendered = chatLog.render(120).join("\n");
    expect(chatLog.children.length).toBe(20);
    expect(rendered).toContain("recreated");
  });

  it("drops stale tool references when old components are pruned", () => {
    const chatLog = new ChatLog(20);
    chatLog.startTool("tool-1", "read_file", { path: "a.txt" });
    for (let i = 0; i < 25; i++) {
      chatLog.addSystem(`overflow-${i}`);
    }

    // Should no-op safely after the tool component is pruned.
    chatLog.updateToolResult("tool-1", { content: [{ type: "text", text: "done" }] });

    expect(chatLog.children.length).toBe(20);
  });

  it("renders streaming assistant as plain text to prevent full-screen redraws", () => {
    // During streaming, the assistant message uses a plain Text component.
    // Markdown re-parsing of the full accumulated text can change lines above the
    // current viewport, triggering expensive full-screen clears on every token.
    const chatLog = new ChatLog();
    chatLog.startAssistant("# Hello", "run-1");
    const rendered = chatLog.render(80).join("\n");
    // Plain text renders markdown syntax as-is (# not stripped/reformatted).
    expect(rendered).toContain("# Hello");
  });

  it("renders finalized assistant with markdown formatting", () => {
    const chatLog = new ChatLog();
    chatLog.startAssistant("# Hello", "run-1");
    chatLog.updateAssistant("# Hello", "run-1");
    chatLog.finalizeAssistant("# Hello", "run-1");
    const rendered = chatLog.render(80).join("\n");
    // Markdown strips the leading '#' and applies heading formatting.
    expect(rendered).not.toContain("# Hello");
    expect(rendered).toContain("Hello");
  });

  it("finalizeAssistant switches streaming body to markdown in-place", () => {
    const chatLog = new ChatLog();
    chatLog.startAssistant("streaming text", "run-1");
    const childCountBefore = chatLog.children.length;
    chatLog.finalizeAssistant("streaming text", "run-1");
    // Component stays in the chatLog (not removed and re-added).
    expect(chatLog.children.length).toBe(childCountBefore);
  });
});

describe("AssistantMessageComponent", () => {
  it("streaming mode renders raw markdown syntax (plain text, no reformatting)", () => {
    const component = new AssistantMessageComponent("# Heading", true);
    const lines = component.render(80).join("\n");
    expect(lines).toContain("# Heading");
  });

  it("non-streaming mode applies markdown formatting", () => {
    const component = new AssistantMessageComponent("# Heading");
    const lines = component.render(80).join("\n");
    // Markdown heading strips '#' and applies styling.
    expect(lines).not.toContain("# Heading");
    expect(lines).toContain("Heading");
  });

  it("finalize switches from plain text to markdown rendering", () => {
    const component = new AssistantMessageComponent("# Heading", true);
    const beforeFinalize = component.render(80).join("\n");
    expect(beforeFinalize).toContain("# Heading");

    component.finalize("# Heading");
    const afterFinalize = component.render(80).join("\n");
    expect(afterFinalize).not.toContain("# Heading");
    expect(afterFinalize).toContain("Heading");
  });

  it("finalize on a non-streaming component just updates text", () => {
    const component = new AssistantMessageComponent("initial");
    component.finalize("updated");
    const lines = component.render(80).join("\n");
    expect(lines).toContain("updated");
    expect(lines).not.toContain("initial");
  });

  it("setText during streaming updates displayed text without reformatting", () => {
    const component = new AssistantMessageComponent("", true);
    component.setText("**bold** text");
    const lines = component.render(80).join("\n");
    // Plain text: asterisks are preserved, not converted to bold formatting.
    expect(lines).toContain("**bold** text");
  });
});
