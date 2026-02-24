import { Container, Spacer, Text } from "@mariozechner/pi-tui";
import { markdownTheme, theme } from "../theme/theme.js";
import { HyperlinkMarkdown } from "./hyperlink-markdown.js";

export class AssistantMessageComponent extends Container {
  private body: HyperlinkMarkdown | Text;
  private streaming: boolean;

  constructor(text: string, streaming = false) {
    super();
    this.streaming = streaming;
    this.body = streaming ? this.makeTextBody(text) : this.makeMarkdownBody(text);
    this.addChild(new Spacer(1));
    this.addChild(this.body);
  }

  private makeMarkdownBody(text: string): HyperlinkMarkdown {
    return new HyperlinkMarkdown(text, 1, 0, markdownTheme, {
      // Keep assistant body text in terminal default foreground so contrast
      // follows the user's terminal theme (dark or light).
      color: (line) => theme.assistantText(line),
    });
  }

  private makeTextBody(text: string): Text {
    // Plain Text during streaming: each update only changes lines at the
    // bottom of the output, preventing full-screen redraws that occur when
    // markdown re-parses earlier content (e.g., on code-fence detection).
    return new Text(text, 1, 0);
  }

  setText(text: string) {
    this.body.setText(text);
  }

  /**
   * Switch from plain-text streaming body to a fully-rendered markdown body.
   * Called once when the run finalizes so the completed response is formatted.
   */
  finalize(text: string) {
    if (!this.streaming) {
      this.body.setText(text);
      return;
    }
    this.streaming = false;
    this.removeChild(this.body);
    this.body = this.makeMarkdownBody(text);
    this.addChild(this.body);
  }
}
