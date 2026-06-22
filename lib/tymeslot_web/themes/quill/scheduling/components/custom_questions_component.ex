defmodule TymeslotWeb.Themes.Quill.Scheduling.Components.CustomQuestionsComponent do
  @moduledoc """
  Quill-themed renderer for the custom-questions step. One question per
  page, glassmorphism card chrome, numeric "N of M" progress indicator
  (hidden when there is exactly one question).

  Receives the shared `Engine` state via assigns and bubbles events back
  to the parent LiveView as `{:step_event, :questions, …}`.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.CoreComponents

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Events
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Renderer, as: InputRenderer

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok, assign(socket, Map.drop(assigns, [:flash, :socket]))}
  end

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: Events

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns = Events.assign_render_state(assigns)

    ~H"""
    <div class="container flex-1" data-locale={@locale}>
      <.page_layout show_steps={true} current_step={3} slug={@duration} username_context={@username_context}>
        <div class="stack">
          <div class="flex-1 flex items-center justify-center px-4 py-4">
            <div class="w-full">
              <.glass_morphism_card class="custom-questions-card">
                <div class="booking-card-body">
                  <%= if @total > 1 do %>
                    <p class="text-quill-secondary text-sm mb-2 custom-questions-progress">
                      {dgettext("booking", "Question %{n} of %{m}", n: @index + 1, m: @total)}
                    </p>
                  <% end %>

                  <.section_header
                    level={2}
                    class="booking-heading-wrapper"
                    title_class="section-header booking-heading"
                  >
                    {@definition["label"]}
                  </.section_header>

                  <%= if @definition["help_text"] do %>
                    <p class="text-quill-secondary mb-2">{@definition["help_text"]}</p>
                  <% end %>

                  <InputRenderer.render
                    definition={@definition}
                    value={@value}
                    myself={@myself}
                  />

                  <%= if @error do %>
                    <p class="form-field__error">{@error}</p>
                  <% end %>

                  <div class="booking-actions">
                    <.action_button
                      type="button"
                      phx-click="back"
                      phx-target={@myself}
                      variant={:secondary}
                      class="flex-1"
                    >
                      <span class="custom-question-cta-nowrap">← {dgettext("booking", "back")}</span>
                    </.action_button>

                    <.action_button
                      type="button"
                      phx-click="next"
                      phx-target={@myself}
                      class="flex-1"
                    >
                      <span class="custom-question-cta-nowrap">
                        <%= if @last? do %>
                          {dgettext("booking", "Continue")} →
                        <% else %>
                          {dgettext("booking", "next")} →
                        <% end %>
                      </span>
                    </.action_button>
                  </div>
                </div>
              </.glass_morphism_card>
            </div>
          </div>
        </div>
      </.page_layout>
    </div>
    """
  end
end
