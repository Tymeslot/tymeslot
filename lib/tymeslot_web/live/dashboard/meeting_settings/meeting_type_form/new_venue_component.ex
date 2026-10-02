defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.NewVenueComponent do
  @moduledoc """
  The small form behind "+ New location" in the location editor: a name and
  an address, saved as one of the organiser's venues without leaving the
  meeting-type form.

  On success it sends the venue to the editor (`editor_id`) as
  `venue_created`; the editor adds it to its choices, ticks it and closes
  this form. Cancel goes straight to the editor (`editor`), which owns
  whether this form is shown. It renders beside the editor's `<form>`, never
  inside it, so the two forms cannot nest.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Venues
  alias Tymeslot.Venues.VenueSchema
  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.LocationEditorComponent
  alias TymeslotWeb.Live.Shared.Flash

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> assign_new(:form, fn -> blank_form() end)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("validate", %{"venue" => params}, socket) do
    changeset =
      %VenueSchema{}
      |> Venues.change_venue(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: :venue))}
  end

  # Under the meeting-type write limit, like saving a venue on the
  # Locations page. Refused, the form keeps what was typed.
  def handle_event("save", %{"venue" => params}, socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check_meeting_type_write_rate_limit(user_id) do
      :ok ->
        create(socket, user_id, params)

      {:error, :rate_limited, message} ->
        Flash.error(message)
        {:noreply, socket}

      {:error, :invalid_user_id} ->
        {:noreply, socket}
    end
  end

  defp create(socket, user_id, params) do
    case Venues.create_venue(user_id, params) do
      {:ok, venue} ->
        LiveView.send_update(LocationEditorComponent,
          id: socket.assigns.editor_id,
          venue_created: venue
        )

        {:noreply, assign(socket, :form, blank_form())}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :venue))}
    end
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="card-glass p-4 mt-4 space-y-3" data-testid="new-venue">
      <h4 class="text-token-sm font-semibold text-tymeslot-800">
        {dgettext("dashboard_meeting_form", "New location")}
      </h4>

      <.form
        for={@form}
        id="new-venue-form"
        novalidate
        phx-change="validate"
        phx-submit="save"
        phx-target={@myself}
        class="space-y-3"
      >
        <CoreComponents.input
          field={@form[:name]}
          label={dgettext("dashboard_meeting_form", "Name")}
          placeholder={dgettext("dashboard_meeting_form", "e.g., Berlin office")}
          maxlength={VenueSchema.name_max_length()}
          required
        />

        <CoreComponents.input
          field={@form[:description]}
          type="textarea"
          rows={3}
          label={dgettext("dashboard_meeting_form", "Address and directions (optional)")}
          placeholder={dgettext("dashboard_meeting_form", "12 High Street, London EC1A 1BB")}
          maxlength={VenueSchema.description_max_length()}
        />

        <div class="flex justify-end gap-2">
          <CoreComponents.action_button
            type="button"
            variant={:secondary}
            phx-click="toggle_new_venue"
            phx-target={@editor}
          >
            {dgettext("dashboard_meeting_form", "Cancel")}
          </CoreComponents.action_button>
          <CoreComponents.action_button type="submit" variant={:primary}>
            {dgettext("dashboard_meeting_form", "Add location")}
          </CoreComponents.action_button>
        </div>
      </.form>
    </div>
    """
  end

  defp blank_form, do: %VenueSchema{} |> Venues.change_venue() |> to_form(as: :venue)
end
