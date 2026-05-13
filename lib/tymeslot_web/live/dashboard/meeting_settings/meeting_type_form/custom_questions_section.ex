defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.CustomQuestionsSection do
  @moduledoc """
  LiveComponent that renders the "Custom questions" section inside the
  meeting type form. Displays the list of existing questions with
  add/edit/delete actions and drag handles for reordering.

  All mutating actions are forwarded to the parent LiveView via
  `send(self(), {:custom_questions, …})` so the parent owns the
  authoritative list in its socket assigns.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.CoreComponents

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <section class="space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h3 class="text-token-base font-semibold text-tymeslot-800">
            {gettext("Custom questions")}
          </h3>
          <p class="text-token-sm text-tymeslot-500 mt-0.5">
            {gettext("Ask bookers extra questions during the booking flow.")}
          </p>
        </div>
        <CoreComponents.action_button
          type="button"
          variant={:secondary}
          phx-click="add_question"
          phx-target={@myself}
        >
          {gettext("Add question")}
        </CoreComponents.action_button>
      </div>

      <%= if @custom_fields == [] do %>
        <div class="card-glass py-6 text-center">
          <CoreComponents.icon
            name="hero-question-mark-circle"
            class="w-8 h-8 mx-auto mb-2 text-tymeslot-400"
          />
          <p class="text-token-sm font-medium text-tymeslot-700">
            {gettext("No custom questions yet")}
          </p>
          <p class="text-token-xs text-tymeslot-500 mt-1">
            {gettext("Add a question and bookers will be asked it when they book this meeting type.")}
          </p>
        </div>
      <% else %>
        <ul
          id={"custom-questions-list-#{@form_id}"}
          phx-hook="QuestionsSortable"
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
                      · {gettext("required")}
                    </span>
                  <% end %>
                </span>
              </div>

              <%!-- Actions --%>
              <div class="flex items-center gap-1 flex-shrink-0">
                <CoreComponents.action_button
                  type="button"
                  variant={:outline}
                  phx-click="edit_question"
                  phx-value-id={q.id}
                  phx-target={@myself}
                  class="!py-1 !px-2 text-token-xs"
                >
                  {gettext("Edit")}
                </CoreComponents.action_button>
                <CoreComponents.action_button
                  type="button"
                  variant={:danger}
                  phx-click="delete_question"
                  phx-value-id={q.id}
                  phx-target={@myself}
                  class="!py-1 !px-2 text-token-xs"
                >
                  {gettext("Delete")}
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
    send(
      self(),
      {:custom_questions, :open_add, socket.assigns.form_id, socket.assigns.custom_fields}
    )

    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("edit_question", %{"id" => id}, socket) do
    question = Enum.find(socket.assigns.custom_fields, &(&1.id == id))
    send(self(), {:custom_questions, :open_edit, question, socket.assigns.form_id})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("delete_question", %{"id" => id}, socket) do
    updated = Enum.reject(socket.assigns.custom_fields, &(&1.id == id))
    send(self(), {:custom_questions, :fields_updated, updated, socket.assigns.form_id})
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

    send(self(), {:custom_questions, :fields_updated, updated, socket.assigns.form_id})
    {:noreply, socket}
  end

  # Converts the internal type atom/string to a human-readable label shown in
  # the list. Intentionally not translated — field type names are technical
  # concepts that are stable across locales in this codebase.
  defp human_type("short_text"), do: gettext("Short text")
  defp human_type("number"), do: gettext("Number")
  defp human_type("single_select"), do: gettext("Single choice")
  defp human_type("multi_select"), do: gettext("Multiple choice")
  defp human_type("yes_no"), do: gettext("Yes / No")
  defp human_type("phone"), do: gettext("Phone")
  defp human_type("url"), do: gettext("URL")
  defp human_type("date"), do: gettext("Date")
  defp human_type("time"), do: gettext("Time")
  defp human_type("note"), do: gettext("Note")
  defp human_type(other), do: other
end
