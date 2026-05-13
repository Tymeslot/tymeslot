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

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Engine

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok, assign(socket, Map.drop(assigns, [:flash, :socket]))}
  end

  @impl Phoenix.LiveComponent
  def handle_event("answer", params, socket) do
    %Engine{} = engine = socket.assigns.engine
    id = Engine.current_definition(engine)["id"]
    value = Map.get(params, "value", params)
    send(self(), {:step_event, :questions, :answer, {id, value}})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("next", _params, socket) do
    send(self(), {:step_event, :questions, :next, nil})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("back", _params, socket) do
    send(self(), {:step_event, :questions, :back, nil})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    engine = assigns.engine
    d = Engine.current_definition(engine)

    assigns =
      assigns
      |> assign(:definition, d)
      |> assign(:value, Map.get(engine.answers, d["id"]))
      |> assign(:error, Map.get(engine.errors, d["id"]))
      |> assign(:index, engine.current_index)
      |> assign(:total, Engine.total(engine))
      |> assign(:last?, engine.current_index == Engine.total(engine) - 1)

    ~H"""
    <div class="container flex-1" data-locale={@locale}>
      <.page_layout show_steps={true} current_step={3} slug={@duration} username_context={@username_context}>
        <div class="stack">
          <div class="flex-1 flex items-center justify-center px-4 py-4">
            <div class="w-full max-w-2xl">
              <.glass_morphism_card class="custom-questions-card">
                <div class="booking-card-body">
                  <%= if @total > 1 do %>
                    <p class="text-quill-secondary text-sm mb-2 custom-questions-progress">
                      {gettext("Question %{n} of %{m}", n: @index + 1, m: @total)}
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

                  <.field_input
                    definition={@definition}
                    value={@value}
                    error={@error}
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
                      disabled={@index == 0}
                      class="flex-1"
                    >
                      ← {gettext("back")}
                    </.action_button>

                    <.action_button
                      type="button"
                      phx-click="next"
                      phx-target={@myself}
                      class="flex-1"
                    >
                      <%= if @last? do %>
                        {gettext("Continue to your details")}
                      <% else %>
                        {gettext("next")} →
                      <% end %>
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

  attr :definition, :map, required: true
  attr :value, :any, required: true
  attr :error, :any, required: true
  attr :myself, :any, required: true

  defp field_input(%{definition: %{"type" => "short_text"}} = assigns) do
    ~H"""
    <input
      type="text"
      name="value"
      value={@value}
      phx-debounce="blur"
      phx-blur="answer"
      phx-target={@myself}
      phx-keydown="next"
      phx-key="Enter"
      class="custom-question-input"
      autocomplete="off"
      autofocus
      aria-label={@definition["label"]}
      aria-required={to_string(@definition["required"] == true)}
    />
    """
  end

  defp field_input(%{definition: %{"type" => "number"}} = assigns) do
    ~H"""
    <input
      type="number"
      name="value"
      value={@value}
      phx-blur="answer"
      phx-target={@myself}
      phx-keydown="next"
      phx-key="Enter"
      class="custom-question-input"
      autofocus
      aria-label={@definition["label"]}
      aria-required={to_string(@definition["required"] == true)}
    />
    """
  end

  defp field_input(%{definition: %{"type" => "phone"}} = assigns) do
    ~H"""
    <input
      type="tel"
      name="value"
      value={@value}
      phx-blur="answer"
      phx-target={@myself}
      phx-keydown="next"
      phx-key="Enter"
      class="custom-question-input"
      autofocus
      aria-label={@definition["label"]}
      aria-required={to_string(@definition["required"] == true)}
    />
    """
  end

  defp field_input(%{definition: %{"type" => "url"}} = assigns) do
    ~H"""
    <input
      type="url"
      name="value"
      value={@value}
      phx-blur="answer"
      phx-target={@myself}
      phx-keydown="next"
      phx-key="Enter"
      class="custom-question-input"
      autofocus
      aria-label={@definition["label"]}
      aria-required={to_string(@definition["required"] == true)}
    />
    """
  end

  defp field_input(%{definition: %{"type" => "date"}} = assigns) do
    ~H"""
    <input
      type="date"
      name="value"
      value={@value}
      phx-blur="answer"
      phx-target={@myself}
      phx-keydown="next"
      phx-key="Enter"
      class="custom-question-input"
      autofocus
      aria-label={@definition["label"]}
      aria-required={to_string(@definition["required"] == true)}
    />
    """
  end

  defp field_input(%{definition: %{"type" => "time"}} = assigns) do
    ~H"""
    <input
      type="time"
      name="value"
      value={@value}
      phx-blur="answer"
      phx-target={@myself}
      phx-keydown="next"
      phx-key="Enter"
      class="custom-question-input"
      autofocus
      aria-label={@definition["label"]}
      aria-required={to_string(@definition["required"] == true)}
    />
    """
  end

  defp field_input(%{definition: %{"type" => "yes_no"}} = assigns) do
    ~H"""
    <label class="custom-question-checkbox">
      <input
        type="checkbox"
        name="value"
        checked={@value == true}
        phx-click="answer"
        phx-value-value={!(@value == true)}
        phx-target={@myself}
      />
      <span>{@definition["label"]}</span>
    </label>
    """
  end

  defp field_input(%{definition: %{"type" => "single_select", "options" => opts}} = assigns)
       when length(opts) <= 5 do
    ~H"""
    <fieldset class="custom-question-radios">
      <legend class="sr-only">{@definition["label"]}</legend>
      <%= for opt <- @definition["options"] do %>
        <label class="custom-question-radio">
          <input
            type="radio"
            name="value"
            value={opt["key"]}
            checked={@value == opt["key"]}
            phx-click="answer"
            phx-value-value={opt["key"]}
            phx-target={@myself}
          />
          <span>{opt["label"]}</span>
        </label>
      <% end %>
    </fieldset>
    """
  end

  defp field_input(%{definition: %{"type" => "single_select"}} = assigns) do
    ~H"""
    <select name="value" phx-change="answer" phx-target={@myself} class="custom-question-input">
      <option value="">{gettext("Select…")}</option>
      <%= for opt <- @definition["options"] do %>
        <option value={opt["key"]} selected={@value == opt["key"]}>{opt["label"]}</option>
      <% end %>
    </select>
    """
  end

  defp field_input(%{definition: %{"type" => "multi_select"}} = assigns) do
    ~H"""
    <fieldset class="custom-question-checkboxes">
      <legend class="sr-only">{@definition["label"]}</legend>
      <%= for opt <- @definition["options"] do %>
        <label class="custom-question-checkbox">
          <input
            type="checkbox"
            value={opt["key"]}
            checked={opt["key"] in (@value || [])}
            phx-click="answer"
            phx-value-value={opt["key"]}
            phx-target={@myself}
          />
          <span>{opt["label"]}</span>
        </label>
      <% end %>
    </fieldset>
    """
  end

  defp field_input(%{definition: %{"type" => "note"}} = assigns) do
    ~H"""
    <div class="custom-question-note">
      <p class="custom-question-note-body">{@definition["body"]}</p>
      <label class="custom-question-checkbox">
        <input
          type="checkbox"
          checked={match?(%{"confirmed" => true}, @value)}
          phx-click="answer"
          phx-value-value="acknowledge"
          phx-target={@myself}
        />
        <span>{gettext("I acknowledge the above")}</span>
      </label>
    </div>
    """
  end
end
