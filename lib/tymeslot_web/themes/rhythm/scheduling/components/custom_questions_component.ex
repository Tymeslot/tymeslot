defmodule TymeslotWeb.Themes.Rhythm.Scheduling.Components.CustomQuestionsComponent do
  @moduledoc """
  Rhythm-themed renderer for the custom-questions step. One question per
  page, slide-box chrome, dots-row progress indicator (hidden when there
  is exactly one question).

  Receives the shared `Engine` state via assigns and bubbles events back
  to the parent LiveView as `{:step_event, :questions, …}`.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Themes.Shared.CustomQuestions.AnswerNormaliser
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Engine

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok, assign(socket, Map.drop(assigns, [:flash, :socket]))}
  end

  @impl Phoenix.LiveComponent
  def handle_event("answer", params, socket) do
    %Engine{} = engine = socket.assigns.engine
    id = Engine.current_definition(engine)["id"]
    raw = Map.get(params, "value", params)
    value = AnswerNormaliser.normalise(raw)
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
    <div class="scheduling-box" data-locale={@locale}>
      <div class="slide-container">
        <div class="slide active">
          <div class="slide-content">
            <%= if @total > 1 do %>
              <div
                class="rhythm-progress-dots"
                role="progressbar"
                aria-label={gettext("Question %{n} of %{m}", n: @index + 1, m: @total)}
                aria-valuenow={@index + 1}
                aria-valuemin={1}
                aria-valuemax={@total}
              >
                <%= for i <- 0..(@total - 1) do %>
                  <span
                    aria-hidden="true"
                    class={["rhythm-progress-dot", i == @index && "is-active", i < @index && "is-done"]}
                  />
                <% end %>
              </div>
            <% end %>

            <h2 class="slide-title">{@definition["label"]}</h2>

            <%= if @definition["help_text"] do %>
              <p class="rhythm-questions-help">{@definition["help_text"]}</p>
            <% end %>

            <.field_input
              definition={@definition}
              value={@value}
              error={@error}
              myself={@myself}
            />

            <%= if @error do %>
              <p class="rhythm-form-error">{@error}</p>
            <% end %>

            <div class="slide-actions horizontal">
              <button
                type="button"
                class="prev-button"
                phx-click="back"
                phx-target={@myself}
                disabled={@index == 0}
              >
                ← {gettext("back")}
              </button>

              <button
                type="button"
                class="submit-button"
                phx-click="next"
                phx-target={@myself}
              >
                <%= if @last? do %>
                  {gettext("Continue to your details")}
                <% else %>
                  {gettext("next")} →
                <% end %>
              </button>
            </div>
          </div>
        </div>
      </div>
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
