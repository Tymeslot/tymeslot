defmodule TymeslotWeb.Dashboard.Locations.LocationsComponent do
  @moduledoc """
  The Locations dashboard page: the organiser's saved in-person locations
  ("venues" in code).

  A card per venue, with how many meeting types offer it; an add and edit
  modal (`VenueFormModal`); and a delete confirmation (`DeleteVenueModal`)
  which, while meeting types offer the venue, first warns which of them it
  will be taken off and which will be left with no address. Everything goes
  through `Tymeslot.Venues`, which scopes every read and write to the
  organiser. Saving and deleting count against the organiser's meeting-type
  write rate limit, as reordering does.

  The cards are dragged into the organiser's order the way meeting types are
  on the Meeting Types list: a sortable hook (`QuestionsSortable`, the
  generic twin of `MeetingTypeSortable`) pushes the new order as a `reorder`
  event, and `Venues.reorder_venues/2` renumbers it in one transaction under
  the same write rate limit. That order is the one venues appear in
  everywhere, the booker's picker included.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Venues
  alias Tymeslot.Venues.VenueSchema
  alias TymeslotWeb.Dashboard.Locations.{DeleteVenueModal, VenueCard, VenueFormModal}
  alias TymeslotWeb.Live.Shared.Flash

  require Logger

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:venue_form, fn -> nil end)
     |> assign_new(:editing_venue, fn -> nil end)
     |> assign_new(:deleting_venue, fn -> nil end)
     |> assign_new(:deleting_in_use, fn -> [] end)
     |> assign_new(:deleting_left_without, fn -> [] end)
     |> assign_new(:list_epoch, fn -> 0 end)
     |> load_venues()}
  end

  @impl Phoenix.LiveComponent
  def handle_event("new_venue", _params, socket),
    do: {:noreply, open_form(socket, %VenueSchema{})}

  def handle_event("edit_venue", %{"id" => id}, socket) do
    case Venues.get_venue(socket.assigns.current_user.id, id) do
      {:ok, venue} -> {:noreply, open_form(socket, venue)}
      {:error, :not_found} -> {:noreply, socket}
    end
  end

  def handle_event("validate_venue", _params, %{assigns: %{editing_venue: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("validate_venue", %{"venue" => params}, socket) do
    changeset =
      socket.assigns.editing_venue
      |> Venues.change_venue(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :venue_form, to_form(changeset, as: :venue))}
  end

  def handle_event("save_venue", _params, %{assigns: %{editing_venue: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("save_venue", %{"venue" => params}, socket) do
    with_write_limit(socket, fn ->
      case save(socket.assigns.editing_venue, socket.assigns.current_user.id, params) do
        {:ok, _venue} ->
          Flash.info(dgettext("dashboard_meeting_types", "Location saved"))
          {:noreply, socket |> close_form() |> load_venues()}

        {:error, %Changeset{} = changeset} ->
          {:noreply, assign(socket, :venue_form, to_form(changeset, as: :venue))}

        # Deleted since the form opened, most likely from another tab.
        {:error, :not_found} ->
          Flash.error(dgettext("dashboard_meeting_types", "This location no longer exists"))
          {:noreply, socket |> close_form() |> load_venues()}
      end
    end)
  end

  def handle_event("close_venue_form", _params, socket), do: {:noreply, close_form(socket)}

  def handle_event("delete_venue", %{"id" => id}, socket) do
    case Venues.get_venue(socket.assigns.current_user.id, id) do
      {:ok, venue} ->
        {:noreply,
         assign(socket,
           deleting_venue: venue,
           deleting_in_use: Venues.meeting_types_using(venue),
           deleting_left_without: Venues.meeting_types_left_without(venue)
         )}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  def handle_event("close_delete_venue", _params, socket), do: {:noreply, close_delete(socket)}

  def handle_event("confirm_delete_venue", _params, %{assigns: %{deleting_venue: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm_delete_venue", _params, socket) do
    with_write_limit(socket, fn ->
      case Venues.delete_venue(socket.assigns.deleting_venue) do
        {:ok, _deleted} ->
          Flash.info(dgettext("dashboard_meeting_types", "Location deleted"))

        # Already gone, most likely from another tab: the reloaded list says so.
        {:error, :not_found} ->
          :ok

        {:error, reason} ->
          Logger.error("Failed to delete location", reason: LogFormat.reason(reason))
          Flash.error(dgettext("dashboard_meeting_types", "Could not delete the location"))
      end

      {:noreply, socket |> close_delete() |> load_venues()}
    end)
  end

  # Mirrors `ServiceSettingsComponent`'s "reorder_meeting_types": the same
  # write rate limit, the context doing the owner-scoped renumbering, and the
  # list reloaded from the database either way. The hook has already moved
  # the dragged card in the browser, and a refused write reloads a list equal
  # to the one assigned, which sends no diff; a new list id makes the browser
  # rebuild it in the saved order, so the page never shows an order that was
  # not saved.
  def handle_event("reorder", %{"ids" => ids}, socket) when is_list(ids) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check_meeting_type_write_rate_limit(user_id) do
      :ok ->
        case reorder(user_id, ids) do
          :ok -> {:noreply, load_venues(socket)}
          :error -> {:noreply, socket |> load_venues() |> reset_list()}
        end

      {:error, :rate_limited, message} ->
        Flash.error(message)
        {:noreply, socket |> load_venues() |> reset_list()}

      {:error, :invalid_user_id} ->
        {:noreply, socket}
    end
  end

  def handle_event("reorder", _params, socket), do: {:noreply, socket}

  # Saving and deleting a venue are meeting-type writes too: deleting one
  # rewrites every meeting type offering it. Refused, the form or the
  # confirmation stays open, so the organiser can try again.
  defp with_write_limit(socket, write) do
    case RateLimiter.check_meeting_type_write_rate_limit(socket.assigns.current_user.id) do
      :ok ->
        write.()

      {:error, :rate_limited, message} ->
        Flash.error(message)
        {:noreply, socket}

      {:error, :invalid_user_id} ->
        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="space-y-6 pb-20" data-testid="locations-page">
      <.section_header
        icon="hero-map-pin"
        title={dgettext("dashboard_meeting_types", "Locations")}
        class="mb-4"
      />

      <p class="text-tymeslot-600">
        {dgettext(
          "dashboard_meeting_types",
          "Save the places you meet people once, then offer them on any in-person meeting type."
        )}
      </p>

      <%= if @venues == [] do %>
        <div class="card-glass text-center py-8 px-4 space-y-3" data-testid="locations-empty">
          <.icon name="hero-map-pin" class="w-12 h-12 mx-auto text-tymeslot-400" />
          <p class="text-tymeslot-700 font-medium">
            {dgettext("dashboard_meeting_types", "No saved locations yet")}
          </p>
          <p class="text-token-sm text-tymeslot-500">
            {dgettext(
              "dashboard_meeting_types",
              "Add an office, a studio or any other place you meet people. In-person meeting types can then offer it to bookers."
            )}
          </p>
          <div class="flex justify-center pt-2">
            <.action_button
              variant={:primary}
              phx-click="new_venue"
              phx-target={@myself}
              data-testid="add-venue"
            >
              <.icon name="hero-plus" class="w-4 h-4" />
              {dgettext("dashboard_meeting_types", "Add location")}
            </.action_button>
          </div>
        </div>
      <% else %>
        <div class="flex justify-end">
          <.action_button
            variant={:primary}
            phx-click="new_venue"
            phx-target={@myself}
            data-testid="add-venue"
          >
            <.icon name="hero-plus" class="w-4 h-4" />
            {dgettext("dashboard_meeting_types", "Add location")}
          </.action_button>
        </div>

        <%!-- One column, because the sortable hook places a dragged card by
             its vertical position. --%>
        <div
          id={"locations-list-#{@list_epoch}"}
          phx-hook="QuestionsSortable"
          phx-target={@myself}
          data-target={@myself}
          data-testid="locations-list"
          class="flex flex-col gap-4"
        >
          <VenueCard.venue_card
            :for={venue <- @venues}
            venue={venue}
            usage={Map.get(@usage, venue.id, 0)}
            myself={@myself}
          />
        </div>
      <% end %>

      <VenueFormModal.venue_form_modal
        :if={@venue_form}
        form={@venue_form}
        mode={if @editing_venue.id, do: :edit, else: :new}
        myself={@myself}
      />

      <DeleteVenueModal.delete_venue_modal
        :if={@deleting_venue}
        venue={@deleting_venue}
        in_use={@deleting_in_use}
        left_without={@deleting_left_without}
        myself={@myself}
      />
    </div>
    """
  end

  defp load_venues(socket) do
    user_id = socket.assigns.current_user.id

    assign(socket,
      venues: Venues.list_venues(user_id),
      usage: Venues.usage_counts(user_id)
    )
  end

  defp reorder(user_id, ids) do
    case Venues.reorder_venues(user_id, ids) do
      {:ok, _count} ->
        Flash.info(dgettext("dashboard_meeting_types", "Locations reordered"))
        :ok

      {:error, reason} ->
        Logger.error("Failed to reorder locations", reason: LogFormat.reason(reason))
        Flash.error(dgettext("dashboard_meeting_types", "Could not reorder the locations"))
        :error
    end
  end

  defp reset_list(socket), do: update(socket, :list_epoch, &(&1 + 1))

  defp open_form(socket, venue) do
    assign(socket,
      editing_venue: venue,
      venue_form: venue |> Venues.change_venue() |> to_form(as: :venue)
    )
  end

  defp close_form(socket), do: assign(socket, editing_venue: nil, venue_form: nil)

  defp close_delete(socket),
    do: assign(socket, deleting_venue: nil, deleting_in_use: [], deleting_left_without: [])

  defp save(%VenueSchema{id: nil}, user_id, params), do: Venues.create_venue(user_id, params)
  defp save(%VenueSchema{} = venue, _user_id, params), do: Venues.update_venue(venue, params)
end
