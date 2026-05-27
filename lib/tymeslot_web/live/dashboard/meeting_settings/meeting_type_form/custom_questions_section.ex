defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.CustomQuestionsSection do
  @moduledoc """
  LiveComponent that renders the "Custom questions" section inside the
  meeting type form. Displays the list of existing questions with
  add/edit/delete actions and drag handles for reordering.

  Mutating actions push assigns directly into the parent `MeetingTypeForm`
  LiveComponent via `send_update/2`. This keeps the round-trip a single
  hop so test helpers like `render_click/1` observe the updated state on
  the very next `render(view)` call.
  """
  use TymeslotWeb, :live_component

  alias Ecto.UUID
  alias Phoenix.LiveView
  alias Tymeslot.CustomFields.FieldDefinition
  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    assigns =
      assigns
      |> Map.put_new(:allowed, true)
      |> Map.put(:placeholder_component, placeholder_component())

    {:ok, assign(socket, assigns)}
  end

  @impl Phoenix.LiveComponent
  def render(%{allowed: false, placeholder_component: nil} = assigns) do
    # SaaS hasn't registered a placeholder component — render a minimal lock
    # notice rather than nothing, so the operator notices the misconfiguration.
    ~H"""
    <section class="card-glass py-6 text-center">
      <p class="text-token-sm text-tymeslot-500">
        Custom booking questions are not available on your current plan.
      </p>
    </section>
    """
  end

  def render(%{allowed: false} = assigns) do
    ~H"""
    <section>
      <.live_component
        module={@placeholder_component}
        id={"custom-questions-upgrade-#{@form_id}"}
        feature={:custom_questions}
        current_user={@current_user}
      />
    </section>
    """
  end

  def render(assigns) do
    ~H"""
    <section class="space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h3 class="text-token-base font-semibold text-tymeslot-800">
            Custom questions
          </h3>
          <p class="text-token-sm text-tymeslot-500 mt-0.5">
            Ask bookers extra questions during the booking flow.
          </p>
        </div>
        <CoreComponents.action_button
          type="button"
          variant={:secondary}
          phx-click="add_question"
          phx-target={@myself}
        >
          Add question
        </CoreComponents.action_button>
      </div>

      <%= if @custom_fields == [] do %>
        <div class="card-glass py-6 text-center">
          <CoreComponents.icon
            name="hero-question-mark-circle"
            class="w-8 h-8 mx-auto mb-2 text-tymeslot-400"
          />
          <p class="text-token-sm font-medium text-tymeslot-700">
            No custom questions yet
          </p>
          <p class="text-token-xs text-tymeslot-500 mt-1">
            Add a question and bookers will be asked it when they book this meeting type.
          </p>
        </div>
      <% else %>
        <ul
          id={"custom-questions-list-#{@form_id}"}
          phx-hook="QuestionsSortable"
          phx-target={@myself}
          data-target={@myself}
          class="space-y-2"
        >
          <%= for {q, i} <- Enum.with_index(@custom_fields) do %>
            <li
              class="card-glass flex items-center gap-3 px-4 py-3"
              data-id={q.id}
              data-index={i}
              draggable="true"
            >
              <%!-- Drag handle --%>
              <span class="drag-handle cursor-grab active:cursor-grabbing text-tymeslot-400 flex-shrink-0">
                <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M4 8h16M4 16h16"
                  />
                </svg>
              </span>

              <%!-- Question info --%>
              <div class="flex-1 min-w-0">
                <span class="text-token-sm font-medium text-tymeslot-800 truncate block">
                  {q.label}
                </span>
                <span class="text-token-xs text-tymeslot-500">
                  {human_type(q.type)}
                  <%= if q.required do %>
                    <span class="ml-1 text-token-xs text-turquoise-600 font-medium">
                      · required
                    </span>
                  <% end %>
                </span>
              </div>

              <%!-- Actions --%>
              <div class="flex items-center gap-1 flex-shrink-0">
                <CoreComponents.action_button
                  type="button"
                  variant={:secondary}
                  phx-click="edit_question"
                  phx-value-id={q.id}
                  phx-target={@myself}
                  class="!py-1 !px-2 text-token-xs"
                >
                  Edit
                </CoreComponents.action_button>
                <CoreComponents.action_button
                  type="button"
                  variant={:danger}
                  phx-click="delete_question"
                  phx-value-id={q.id}
                  phx-target={@myself}
                  class="!py-1 !px-2 text-token-xs"
                >
                  Delete
                </CoreComponents.action_button>
              </div>
            </li>
          <% end %>
        </ul>
      <% end %>
    </section>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("add_question", _params, socket) do
    empty = %FieldDefinition{
      id: UUID.generate(),
      type: "short_text",
      position: length(socket.assigns.custom_fields)
    }

    LiveView.send_update(MeetingTypeForm,
      id: socket.assigns.form_id,
      editing_question: empty,
      editing_question_mode: :add
    )

    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("edit_question", %{"id" => id}, socket) do
    question = Enum.find(socket.assigns.custom_fields, &(&1.id == id))

    LiveView.send_update(MeetingTypeForm,
      id: socket.assigns.form_id,
      editing_question: question,
      editing_question_mode: :edit
    )

    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("delete_question", %{"id" => id}, socket) do
    updated = Enum.reject(socket.assigns.custom_fields, &(&1.id == id))

    LiveView.send_update(MeetingTypeForm,
      id: socket.assigns.form_id,
      custom_fields: updated,
      editing_question: nil
    )

    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("reorder", %{"ids" => ids}, socket) do
    by_id = Map.new(socket.assigns.custom_fields, &{&1.id, &1})

    updated =
      ids
      |> Enum.with_index()
      |> Enum.flat_map(fn {id, i} ->
        case Map.fetch(by_id, id) do
          {:ok, field} -> [%{field | position: i}]
          :error -> []
        end
      end)

    LiveView.send_update(MeetingTypeForm,
      id: socket.assigns.form_id,
      custom_fields: updated,
      editing_question: nil
    )

    {:noreply, socket}
  end

  defp human_type("short_text"), do: "Short text"
  defp human_type("number"), do: "Number"
  defp human_type("single_select"), do: "Single choice"
  defp human_type("multi_select"), do: "Multiple choice"
  defp human_type("yes_no"), do: "Yes / No"
  defp human_type("phone"), do: "Phone"
  defp human_type("url"), do: "URL"
  defp human_type("date"), do: "Date"
  defp human_type("time"), do: "Time"
  defp human_type("note"), do: "Note"
  defp human_type(other), do: other

  defp placeholder_component do
    # The :feature_placeholder_components config can be either a keyword list
    # (the natural shape when written in Mix config) or a map, so we use
    # bracket access which works for both. SaaS sets this; Core standalone
    # leaves it unset (nil), which short-circuits the locked branch.
    case Application.get_env(:tymeslot, :feature_placeholder_components) do
      nil -> nil
      placeholders -> placeholders[:custom_questions]
    end
  end
end
