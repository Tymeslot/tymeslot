defmodule TymeslotWeb.Dashboard.Locations.DeleteVenueModal do
  @moduledoc """
  Confirmation before a saved location is deleted.

  For a venue no meeting type offers it is a plain "cannot be undone"
  question. For one in use it is a warning first: the meeting types it will
  be taken off, and of those, the ones left with an in-person location that
  lists no venue, whose bookers are then told the address is arranged after
  booking. Meetings already booked there keep their address. Deleting is
  allowed either way (see `Tymeslot.Venues.delete_venue/1`).
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS

  attr :venue, :map, required: true
  attr :in_use, :list, required: true, doc: "the meeting types offering the venue"

  attr :left_without, :list,
    required: true,
    doc: "of `in_use`, those left with an in-person location listing no venue"

  attr :myself, :any, required: true

  @spec delete_venue_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def delete_venue_modal(assigns) do
    ~H"""
    <.modal
      id="delete-venue-modal"
      show
      on_cancel={JS.push("close_delete_venue", target: @myself)}
      size={:medium}
    >
      <:header>
        <div class="flex items-center gap-2">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5 text-red-500" />
          <span>{dgettext("dashboard_meeting_types", "Delete location")}</span>
        </div>
      </:header>

      <%= if @in_use == [] do %>
        <p class="text-tymeslot-700">
          {dgettext("dashboard_meeting_types", "Delete %{name}? This cannot be undone.",
            name: @venue.name
          )}
        </p>
      <% else %>
        <div class="space-y-4 text-tymeslot-700">
          <div class="space-y-2">
            <p>
              {dgettext(
                "dashboard_meeting_types",
                "%{name} is offered by these meeting types. Deleting it removes it from them:",
                name: @venue.name
              )}
            </p>
            <ul class="list-disc pl-5" data-testid="venue-in-use">
              <li :for={meeting_type <- @in_use}>{meeting_type.name}</li>
            </ul>
          </div>

          <.info_box :if={@left_without != []} variant={:warning}>
            <div class="space-y-2">
              <p>
                {dgettext(
                  "dashboard_meeting_types",
                  "These are then left with an in-person option that has no address, so their bookers will be told the address is arranged after booking:"
                )}
              </p>
              <ul class="list-disc pl-5" data-testid="venue-left-without">
                <li :for={meeting_type <- @left_without}>{meeting_type.name}</li>
              </ul>
            </div>
          </.info_box>

          <p class="text-token-sm">
            {dgettext(
              "dashboard_meeting_types",
              "Meetings already booked there keep their address. This cannot be undone."
            )}
          </p>
        </div>
      <% end %>

      <:footer>
        <div class="flex justify-end gap-3">
          <.action_button variant={:secondary} phx-click="close_delete_venue" phx-target={@myself}>
            {dgettext("dashboard_meeting_types", "Cancel")}
          </.action_button>
          <.action_button
            variant={:danger}
            phx-click="confirm_delete_venue"
            phx-target={@myself}
            data-testid="confirm-delete-venue"
          >
            {dgettext("dashboard_meeting_types", "Delete location")}
          </.action_button>
        </div>
      </:footer>
    </.modal>
    """
  end
end
