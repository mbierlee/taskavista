/* <tv-agent-chat></tv-agent-chat>

   The agent chat, a panel down the right of the window beside whatever
   screen is showing: a tab per chat with an AI agent, the open one's
   messages, and a box to write the next one in. "+" opens a tab that asks
   which agent to talk to. An agent can be in several chats at once, each
   its own session; its chats after the first are numbered ("Ada 2"), and
   keep their number when another of them ends. The ✕ on a tab ends that chat, and
   the ✕ at the end of the row hides the panel, leaving the chats as they
   are.

   It holds no chats of its own: it shows the `chat` in the store, naming the
   agents from the store's `agents`, and sets `open` on itself while the
   store says it shows. What is being typed is kept here, per chat.

   Events (bubbling and composed):
     chat-hide    the ✕ at the end of the tab row was pressed
     chat-new     "+" was pressed
     chat-select  detail { sessionId }           a tab was picked
     chat-end     detail { sessionId }           a tab's ✕ was pressed
     chat-pick    detail { sessionId, agentId }  an agent was picked in the
                  "New chat" tab `sessionId`
     chat-send    detail { sessionId, text }     a message was sent */

import { attachTemplate, loadTemplate } from "./template.js";
import "./tv-text-box.js";
import { store } from "../store.js";

const template = await loadTemplate("tv-agent-chat.html");

export class TvAgentChat extends HTMLElement {
  #chat = store.state.chat;
  #agents = store.state.agents;
  #unwatch = [];

  /* What has been typed and not sent, by session id. */
  #drafts = new Map();
  /* The session whose draft the box holds, and the messages last drawn,
     with whether they were waiting for a reply. */
  #shownSession = null;
  #shownMessages = null;
  #shownWaiting = false;

  #panel;
  #tabs;
  #tabTemplate;
  #chatView;
  #agentMeta;
  #messages;
  #picker;
  #choices;
  #choiceTemplate;
  #status;
  #compose;
  #send;

  #onMove = () => this.#placePanel();

  constructor() {
    super();
    const root = attachTemplate(this, template);

    this.#panel = root.querySelector(".panel");
    this.#tabs = root.querySelector(".tabs");
    this.#tabTemplate = root.querySelector(".tab-template");
    this.#chatView = root.querySelector(".chat");
    this.#agentMeta = root.querySelector(".agent-meta");
    this.#messages = root.querySelector(".messages");
    this.#picker = root.querySelector(".picker");
    this.#choices = root.querySelector(".choices");
    this.#choiceTemplate = root.querySelector(".choice-template");
    this.#status = root.querySelector(".picker .status");
    this.#compose = root.querySelector(".compose");
    this.#send = root.querySelector(".send");

    root
      .querySelector(".hide")
      .addEventListener("click", () => this.#emit("chat-hide", {}));
    root
      .querySelector(".new")
      .addEventListener("click", () => this.#emit("chat-new", {}));
    this.#send.addEventListener("click", () => this.#onSend());
    this.#compose.addEventListener("text-commit", (event) => {
      event.stopPropagation();
      this.#onSend();
    });
    /* Nothing to back out of: Escape leaves the draft as it is. */
    this.#compose.addEventListener("text-cancel", (event) => {
      event.stopPropagation();
    });
  }

  connectedCallback() {
    this.#unwatch = [
      store.watch(
        (state) => state.chat,
        (chat) => {
          this.#chat = chat;
          this.#render();
        },
      ),
      store.watch(
        (state) => state.agents,
        (agents) => {
          this.#agents = agents;
          this.#render();
        },
      ),
    ];
  }

  disconnectedCallback() {
    this.#unwatch.forEach((unwatch) => unwatch());
    this.#stopListening();
  }

  get #session() {
    return this.#chat.sessions.find((s) => s.id === this.#chat.current) ?? null;
  }

  #render() {
    const wasOpen = this.hasAttribute("open");
    this.toggleAttribute("open", this.#chat.open);
    if (this.#chat.open && !wasOpen) {
      this.#placePanel();
      window.addEventListener("scroll", this.#onMove, { passive: true });
      window.addEventListener("resize", this.#onMove);
    } else if (!this.#chat.open && wasOpen) {
      this.#stopListening();
    }

    this.#renderTabs();

    const session = this.#session;
    this.#swapDraft(session);
    const agent = session ? this.#agent(session.agentId) : null;
    this.#chatView.hidden = !agent;
    this.#picker.hidden = !session || agent !== null;

    if (agent) {
      this.#renderChat(session, agent);
    } else if (session) {
      this.#shownMessages = null;
      this.#renderPicker();
    }
  }

  #renderTabs() {
    const { sessions, current } = this.#chat;
    this.#tabs.replaceChildren(
      ...sessions.map((session) => {
        const tab = this.#tabTemplate.content.firstElementChild.cloneNode(true);
        const agentName = this.#agent(session.agentId)?.name;
        let name = "New chat";
        if (agentName !== undefined) {
          name =
            session.number === 1 ? agentName : `${agentName} ${session.number}`;
        }
        const isCurrent = session.id === current;
        tab.toggleAttribute("current", isCurrent);

        const select = tab.querySelector(".tab-name");
        select.textContent = name;
        select.setAttribute("aria-selected", String(isCurrent));
        select.addEventListener("click", () =>
          this.#emit("chat-select", { sessionId: session.id }),
        );

        const end = tab.querySelector(".tab-close");
        const label =
          session.agentId === null ? "Close New chat" : `End the chat with ${name}`;
        end.setAttribute("aria-label", label);
        end.title = label;
        end.addEventListener("click", () => {
          this.#drafts.delete(session.id);
          this.#emit("chat-end", { sessionId: session.id });
        });
        return tab;
      }),
    );
    this.#tabs
      .querySelector(".tab[current]")
      ?.scrollIntoView({ block: "nearest", inline: "nearest" });
  }

  #renderChat(session, agent) {
    /* Cut off when it is longer than the panel is wide, so the whole of it
       is in the tooltip. */
    this.#agentMeta.textContent = this.#agentMeta.title =
      this.#describe(agent).join(" · ");
    this.#compose.removeAttribute("disabled");
    this.#compose.setAttribute("label", `Message ${agent.name}`);
    this.#compose.setAttribute("placeholder", `Message ${agent.name}…`);
    /* The box stays open while the agent answers, so the next message can
       be written, but it cannot be sent until the answer is in. */
    this.#send.disabled = session.waiting;

    if (
      session.messages === this.#shownMessages &&
      session.waiting === this.#shownWaiting
    ) {
      return;
    }
    this.#shownMessages = session.messages;
    this.#shownWaiting = session.waiting;
    if (session.messages.length === 0) {
      const empty = document.createElement("p");
      empty.className = "empty";
      empty.textContent = `No messages with ${agent.name} yet.`;
      this.#messages.replaceChildren(empty);
    } else {
      this.#messages.replaceChildren(
        ...session.messages.map((message) => {
          const el = document.createElement("div");
          el.className = `message ${message.from}`;
          el.textContent = message.text;
          return el;
        }),
      );
    }
    if (session.waiting) {
      const waiting = document.createElement("p");
      waiting.className = "waiting";
      waiting.textContent = `${agent.name} is answering`;
      const dots = document.createElement("span");
      dots.className = "dots";
      dots.setAttribute("aria-hidden", "true");
      dots.innerHTML = "<span>.</span><span>.</span><span>.</span>";
      waiting.append(dots);
      this.#messages.append(waiting);
    }
    this.#messages.scrollTop = this.#messages.scrollHeight;
  }

  /* Every agent is offered, in the order the settings list them, whether
     or not it is in a chat already: picking it starts another. */
  #renderPicker() {
    this.#compose.setAttribute("disabled", "");
    this.#compose.setAttribute("label", "Message");
    this.#compose.setAttribute("placeholder", "Pick an agent first");
    this.#send.disabled = true;

    const { status, list } = this.#agents;
    this.#choices.replaceChildren(
      ...list.map((agent) => {
        const choice =
          this.#choiceTemplate.content.firstElementChild.cloneNode(true);
        choice.querySelector(".choice-name").textContent = agent.name;
        const meta = choice.querySelector(".choice-meta");
        meta.textContent = meta.title = [
          ...this.#describe(agent),
          ...(agent.taskScheduler ? ["Scheduler"] : []),
        ].join(" · ");
        choice.querySelector(".choice-go").textContent = "→";
        choice.addEventListener("click", () => this.#onPick(agent));
        return choice;
      }),
    );

    const message =
      status === "loading"
        ? "Loading the agents…"
        : status === "unavailable"
          ? "The agents could not be loaded."
          : list.length === 0
            ? "There are no agents yet. Add one in the Taskavista settings (⚙)."
            : "";
    this.#status.textContent = message;
    this.#status.hidden = message === "";
  }

  #onPick(agent) {
    this.#emit("chat-pick", { sessionId: this.#chat.current, agentId: agent.id });
    this.#compose.focus();
  }

  #onSend() {
    const session = this.#session;
    const text = this.#compose.value.trim();
    if (!session || session.agentId === null || session.waiting || text === "") {
      return;
    }
    this.#compose.value = "";
    this.#drafts.delete(session.id);
    this.#emit("chat-send", { sessionId: session.id, text });
  }

  /* The box holds the draft of the session showing, so switching tabs puts
     away one draft and brings back the other. */
  #swapDraft(session) {
    const id = session?.id ?? null;
    if (id === this.#shownSession) {
      return;
    }
    if (this.#shownSession !== null) {
      const draft = this.#compose.value;
      if (draft === "") {
        this.#drafts.delete(this.#shownSession);
      } else {
        this.#drafts.set(this.#shownSession, draft);
      }
    }
    this.#shownSession = id;
    this.#shownMessages = null;
    this.#compose.value = this.#drafts.get(id) ?? "";
  }

  #agent(agentId) {
    if (agentId === null) {
      return null;
    }
    return this.#agents.list.find((a) => a.id === agentId) ?? null;
  }

  /* The agent's runtime and model by name, or by id if the list has no such
     entry, as the settings show them. */
  #describe(agent) {
    const { runtimes, models } = this.#agents;
    return [
      runtimes.find((r) => r.id === agent.runtime)?.name ?? agent.runtime,
      models.find((m) => m.id === agent.model)?.name ?? agent.model,
    ];
  }

  /* The panel covers the window below the topbar, which scrolls with the
     page, so it starts wherever the host, just under the topbar, now is. */
  #placePanel() {
    const top = Math.max(0, this.getBoundingClientRect().top);
    this.#panel.style.setProperty("--top", `${top}px`);
  }

  #stopListening() {
    window.removeEventListener("scroll", this.#onMove);
    window.removeEventListener("resize", this.#onMove);
  }

  #emit(type, detail) {
    this.dispatchEvent(
      new CustomEvent(type, { bubbles: true, composed: true, detail }),
    );
  }
}

customElements.define("tv-agent-chat", TvAgentChat);
