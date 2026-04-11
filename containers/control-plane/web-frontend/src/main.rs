mod virtual_list;

use gloo_net::http::Request;
use leptos::ev::SubmitEvent;
use leptos::prelude::*;
use serde::{Deserialize, Serialize};
use virtual_list::visible_window;
use wasm_bindgen::JsCast;
use web_sys::HtmlElement;

const TIMELINE_ROW_HEIGHT: i32 = 112;
const TIMELINE_OVERSCAN: usize = 4;

#[derive(Clone, Debug, PartialEq, Eq)]
struct ConversationEntry {
    id: usize,
    role: &'static str,
    content: String,
}

#[derive(Serialize)]
struct ChatRequest {
    prompt: String,
}

#[derive(Deserialize)]
struct ChatResponse {
    response: String,
}

#[cfg(target_arch = "wasm32")]
fn main() {
    console_error_panic_hook::set_once();
    mount_to_body(App);
}

#[cfg(not(target_arch = "wasm32"))]
fn main() {}

#[component]
fn App() -> impl IntoView {
    let prompt = RwSignal::new(String::new());
    let pending = RwSignal::new(false);
    let error = RwSignal::new(None::<String>);
    let entries = RwSignal::new(Vec::<ConversationEntry>::new());
    let next_id = RwSignal::new(0usize);

    let on_submit = move |event: SubmitEvent| {
        event.prevent_default();
        let request_prompt = prompt.get_untracked().trim().to_string();
        if request_prompt.is_empty() {
            error.set(Some(String::from("Prompt must not be empty")));
            return;
        }

        pending.set(true);
        error.set(None);
        let prompt_signal = prompt;
        let pending_signal = pending;
        let error_signal = error;
        let entries_signal = entries;
        let next_id_signal = next_id;
        leptos::task::spawn_local(async move {
            let request = match Request::post("/api/chat")
                .header("Content-Type", "application/json")
                .json(&ChatRequest {
                    prompt: request_prompt.clone(),
                }) {
                Ok(request) => request,
                Err(error) => {
                    error_signal.set(Some(format!("failed to encode request: {error}")));
                    pending_signal.set(false);
                    return;
                }
            };

            match request.send().await {
                Ok(response) if response.ok() => match response.json::<ChatResponse>().await {
                    Ok(payload) => {
                        let user_id = next_id_signal.get_untracked();
                        let assistant_id = user_id + 1;
                        next_id_signal.set(assistant_id + 1);
                        entries_signal.update(|items| {
                            items.push(ConversationEntry {
                                id: user_id,
                                role: "Prompt",
                                content: request_prompt.clone(),
                            });
                            items.push(ConversationEntry {
                                id: assistant_id,
                                role: "Response",
                                content: payload.response,
                            });
                        });
                        prompt_signal.set(String::new());
                    }
                    Err(error) => {
                        error_signal.set(Some(format!("failed to decode response: {error}")));
                    }
                },
                Ok(response) => {
                    let body = response
                        .text()
                        .await
                        .unwrap_or_else(|_| String::from("backend returned an error"));
                    error_signal.set(Some(body));
                }
                Err(error) => {
                    error_signal.set(Some(format!("request failed: {error}")));
                }
            }

            pending_signal.set(false);
        });
    };

    view! {
        <main class="shell">
            <style>
                {r#"
                :root {
                  color-scheme: light dark;
                  font-family: Inter, system-ui, sans-serif;
                  background: #020617;
                  color: #e2e8f0;
                }
                body {
                  margin: 0;
                  background: #020617;
                  color: #e2e8f0;
                }
                .shell {
                  max-width: 1100px;
                  margin: 0 auto;
                  padding: 2rem 1.25rem 3rem;
                }
                .hero {
                  display: grid;
                  gap: 0.5rem;
                  margin-bottom: 1.25rem;
                }
                .hero h1 {
                  margin: 0;
                  font-size: clamp(1.75rem, 4vw, 2.5rem);
                }
                .hero p {
                  margin: 0;
                  color: #94a3b8;
                  line-height: 1.6;
                }
                .layout {
                  display: grid;
                  gap: 1rem;
                }
                .card {
                  background: rgba(15, 23, 42, 0.92);
                  border: 1px solid #1e293b;
                  border-radius: 1rem;
                  box-shadow: 0 18px 40px rgba(2, 6, 23, 0.35);
                }
                .composer {
                  padding: 1rem;
                }
                .composer form {
                  display: grid;
                  gap: 0.75rem;
                }
                textarea {
                  width: 100%;
                  min-height: 9rem;
                  padding: 0.875rem 1rem;
                  box-sizing: border-box;
                  resize: vertical;
                  border-radius: 0.875rem;
                  border: 1px solid #334155;
                  background: #0f172a;
                  color: inherit;
                  font: inherit;
                }
                .composer-footer {
                  display: flex;
                  justify-content: space-between;
                  align-items: center;
                  gap: 0.75rem;
                }
                button {
                  border: 0;
                  border-radius: 999px;
                  padding: 0.75rem 1.2rem;
                  font: inherit;
                  color: white;
                  background: #2563eb;
                  cursor: pointer;
                }
                button[disabled] {
                  opacity: 0.65;
                  cursor: wait;
                }
                .error {
                  color: #fecaca;
                  margin: 0;
                }
                .timeline {
                  height: 420px;
                  overflow-y: auto;
                  padding: 0.5rem;
                }
                .entry {
                  min-height: 96px;
                  box-sizing: border-box;
                  border-radius: 0.875rem;
                  border: 1px solid #1e293b;
                  background: #0f172a;
                  padding: 0.875rem 1rem;
                  display: grid;
                  gap: 0.5rem;
                  margin-bottom: 0.75rem;
                }
                .entry h2 {
                  margin: 0;
                  font-size: 0.95rem;
                  color: #93c5fd;
                }
                .entry pre {
                  margin: 0;
                  white-space: pre-wrap;
                  word-break: break-word;
                  line-height: 1.5;
                  max-height: 4.5rem;
                  overflow: auto;
                }
                .empty {
                  padding: 1.5rem;
                  color: #94a3b8;
                }
                @media (min-width: 900px) {
                  .layout {
                    grid-template-columns: minmax(0, 1.1fr) minmax(320px, 0.9fr);
                  }
                }
                "#}
            </style>
            <section class="hero">
                <h1>"Copilot ACP Control Plane"</h1>
                <p>
                    "The browser stays light by rendering only the visible slice of the conversation log while the Axum backend handles ACP communication."
                </p>
            </section>
            <section class="layout">
                <section class="card composer">
                    <form on:submit=on_submit>
                        <label for="prompt">"Prompt"</label>
                        <textarea
                            id="prompt"
                            prop:value=move || prompt.get()
                            on:input=move |event| prompt.set(event_target_value(&event))
                            placeholder="Ask Copilot through the ACP backend"
                        ></textarea>
                        <div class="composer-footer">
                            <p class="error">{move || error.get().unwrap_or_default()}</p>
                            <button type="submit" disabled=move || pending.get()>
                                {move || if pending.get() { "Sending..." } else { "Send prompt" }}
                            </button>
                        </div>
                    </form>
                </section>
                <section class="card">
                    <VirtualConversationList entries=entries />
                </section>
            </section>
        </main>
    }
}

#[component]
fn VirtualConversationList(entries: RwSignal<Vec<ConversationEntry>>) -> impl IntoView {
    let scroll_top = RwSignal::new(0_i32);
    let viewport_height = RwSignal::new(420_i32);

    let window = Memo::new(move |_| {
        visible_window(
            entries.with(|items| items.len()),
            scroll_top.get(),
            viewport_height.get(),
            TIMELINE_ROW_HEIGHT,
            TIMELINE_OVERSCAN,
        )
    });

    let visible_entries = Memo::new(move |_| {
        let current_window = window.get();
        entries.with(|items| items[current_window.start..current_window.end].to_vec())
    });

    let on_scroll = move |event: web_sys::Event| {
        if let Some(target) = event
            .target()
            .and_then(|value| value.dyn_into::<HtmlElement>().ok())
        {
            scroll_top.set(target.scroll_top());
            viewport_height.set(target.client_height());
        }
    };

    view! {
        <div class="timeline" on:scroll=on_scroll>
            <Show
                when=move || !entries.with(|items| items.is_empty())
                fallback=|| view! { <div class="empty">"Responses will appear here."</div> }
            >
                <div style=move || format!("height: {}px;", window.get().top_padding)></div>
                <For
                    each=move || visible_entries.get()
                    key=|entry| entry.id
                    children=move |entry| {
                        view! {
                            <article class="entry">
                                <h2>{entry.role}</h2>
                                <pre>{entry.content}</pre>
                            </article>
                        }
                    }
                />
                <div style=move || format!("height: {}px;", window.get().bottom_padding)></div>
            </Show>
        </div>
    }
}
