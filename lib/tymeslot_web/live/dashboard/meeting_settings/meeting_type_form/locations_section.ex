defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.LocationsSection do
  @moduledoc """
  LiveComponent that renders the "Location" section inside the meeting type
  form: the ordered list of locations this meeting type can be held at, with
  add/edit/delete actions and drag handles for reordering.

  One location means the booker is simply told where the meeting is. Two or
  more and the booker chooses, which the section says explicitly so the host
  can see what adding a second option does before they add it.

  Mutating actions push assigns directly into the parent `MeetingTypeForm`
  LiveComponent via `send_update/2`, the same single-hop round-trip
  `CustomQuestionsSection` uses so `render_click/1` observes the updated
  state on the very next `render(view)`.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.UUID
  alias Phoenix.LiveView
  alias Tymeslot.MeetingTypes.LocationOption
  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm
  alias TymeslotWeb.Helpers.LocationIcons

  @impl Phoenix.LiveComponent
  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <section class="space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <div class="flex items-center gap-2">
            <CoreComponents.icon name="hero-map-pin" class="w-5 h-5 text-turquoise-500" />
            <h3 class="text-token-base font-semibold text-tymeslot-800">
              {dgettext("dashboard_meeting_form", "Location")}
            </h3>
          </div>
          <p class="text-token-sm text-tymeslot-500 mt-0.5">
            {location_hint(@locations)}
          </p>
        </div>
        <CoreComponents.action_button
          type="button"
          variant={:secondary}
          phx-click="add_location"
          phx-target={@myself}
          data-testid="add-location"
        >
          {dgettext("dashboard_meeting_form", "Add location")}
        </CoreComponents.action_button>
      </div>

      <%!-- Reuses the questions list's sortable hook: it is generic over
           `[data-id]` children and pushes the same "reorder" event, so a
           second copy would only be a copy. --%>
      <ul
        id={"locations-list-#{@form_id}"}
        phx-hook="QuestionsSortable"
        phx-target={@myself}
        data-target={@myself}
        data-testid="locations-list"
        class="space-y-2"
      >
        <%= for {location, index} <- Enum.with_index(@locations) do %>
          <li
            class="card-glass flex items-center gap-3 px-4 py-3"
            data-id={location.id}
            data-index={index}
            data-testid="location-row"
            draggable="true"
          >
            <span class="drag-handle cursor-grab active:cursor-grabbing text-tymeslot-400 shrink-0">
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M4 8h16M4 16h16"
                />
              </svg>
            </span>

            <CoreComponents.icon
              name={LocationIcons.icon(location.kind)}
              class="w-5 h-5 text-turquoise-500 shrink-0"
            />

            <div class="flex-1 min-w-0">
              <span class="text-token-sm font-medium text-tymeslot-800 truncate block">
                {location.label}
              </span>
              <span class="text-token-xs text-tymeslot-500 truncate block">
                {summary(location, @video_integrations)}
              </span>
            </div>

            <div class="flex items-center gap-1 shrink-0">
              <CoreComponents.action_button
                type="button"
                variant={:secondary}
                phx-click="edit_location"
                phx-value-id={location.id}
                phx-target={@myself}
                class="py-1! px-2! text-token-xs"
              >
                {dgettext("dashboard_meeting_form", "Edit")}
              </CoreComponents.action_button>
              <%!-- A meeting type has to be held somewhere, so the last
                    location cannot be deleted; the host edits it instead. --%>
              <CoreComponents.action_button
                :if={length(@locations) > 1}
                type="button"
                variant={:danger}
                phx-click="delete_location"
                phx-value-id={location.id}
                phx-target={@myself}
                class="py-1! px-2! text-token-xs"
              >
                {dgettext("dashboard_meeting_form", "Delete")}
              </CoreComponents.action_button>
            </div>
          </li>
        <% end %>
      </ul>
    </section>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("add_location", _params, socket) do
    empty = %LocationOption{
      id: UUID.generate(),
      kind: "in_person",
      position: length(socket.assigns.locations)
    }

    LiveView.send_update(MeetingTypeForm,
      id: socket.assigns.form_id,
      editing_location: empty,
      editing_location_mode: :add
    )

    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("edit_location", %{"id" => id}, socket) do
    location = Enum.find(socket.assigns.locations, &(&1.id == id))

    LiveView.send_update(MeetingTypeForm,
      id: socket.assigns.form_id,
      editing_location: location,
      editing_location_mode: :edit
    )

    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("delete_location", %{"id" => id}, socket) do
    remaining = Enum.reject(socket.assigns.locations, &(&1.id == id))

    # Deleting the only location would leave the meeting type with nowhere to
    # be held, which the schema refuses; the button is hidden in that case and
    # this guard is the server-side half of the same rule.
    if remaining == [] do
      {:noreply, socket}
    else
      LiveView.send_update(MeetingTypeForm,
        id: socket.assigns.form_id,
        locations: reindex(remaining),
        editing_location: nil
      )

      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("reorder", %{"ids" => ids}, socket) when is_list(ids) do
    locations = socket.assigns.locations
    existing_ids = Enum.map(locations, & &1.id)

    # Accept the client's order only when it is a genuine permutation of the
    # current ids. A tampered list could otherwise duplicate a location
    # (repeated id) or silently drop one (missing id).
    if MapSet.new(ids) == MapSet.new(existing_ids) and length(ids) == length(existing_ids) do
      by_id = Map.new(locations, &{&1.id, &1})

      updated =
        ids
        |> Enum.with_index()
        |> Enum.map(fn {id, index} -> %{Map.fetch!(by_id, id) | position: index} end)

      LiveView.send_update(MeetingTypeForm,
        id: socket.assigns.form_id,
        locations: updated,
        editing_location: nil
      )
    end

    {:noreply, socket}
  end

  def handle_event("reorder", _params, socket), do: {:noreply, socket}

  defp reindex(locations) do
    locations
    |> Enum.with_index()
    |> Enum.map(fn {location, index} -> %{location | position: index} end)
  end

  defp location_hint([_single]) do
    dgettext(
      "dashboard_meeting_form",
      "Where this meeting is held. Add a second location and bookers will be asked to choose."
    )
  end

  defp location_hint(_locations) do
    dgettext("dashboard_meeting_form", "Bookers will be asked to choose one of these.")
  end

  # The second line of a row: enough to tell two similar options apart at a
  # glance, which for a video option with one provider is the account the
  # room lands on, and with several, the providers the booker picks between.
  defp summary(%LocationOption{kind: "video"} = location, video_integrations) do
    case Enum.filter(video_integrations, &(&1.id in location.video_integration_ids)) do
      [] ->
        dgettext("dashboard_meeting_form", "Video call: integration no longer available")

      [integration] ->
        [integration.name, integration.provider_account_email]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" · ")

      integrations ->
        dgettext("dashboard_meeting_form", "The booker picks: %{providers}",
          providers: Enum.map_join(integrations, ", ", & &1.name)
        )
    end
  end

  defp summary(%LocationOption{kind: "phone", collect_from_guest: true}, _integrations),
    do: dgettext("dashboard_meeting_form", "Phone call: the booker gives their number")

  defp summary(%LocationOption{details: details}, _integrations)
       when is_binary(details) and details != "",
       do: details

  defp summary(%LocationOption{kind: "phone"}, _integrations),
    do: dgettext("dashboard_meeting_form", "Phone call")

  defp summary(%LocationOption{kind: "in_person"}, _integrations),
    do: dgettext("dashboard_meeting_form", "In person")

  defp summary(_location, _integrations), do: dgettext("dashboard_meeting_form", "No details")
end
