defmodule TymeslotWeb.Dashboard.Locations.VenueFormModal do
  @moduledoc """
  The add and edit modal on the Locations page: a name and a free-text
  address. Its events go to the owning `LocationsComponent` (`@myself`),
  which validates and saves through `Tymeslot.Venues`.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.Venues.VenueSchema

  attr :form, Phoenix.HTML.Form, required: true
  attr :mode, :atom, required: true, values: [:new, :edit]
  attr :myself, :any, required: true

  @spec venue_form_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def venue_form_modal(assigns) do
    ~H"""
    <.modal
      id="venue-form-modal"
      show
      on_cancel={JS.push("close_venue_form", target: @myself)}
      size={:medium}
    >
      <:header>
        <%= if @mode == :edit do %>
          {dgettext("dashboard_meeting_types", "Edit location")}
        <% else %>
          {dgettext("dashboard_meeting_types", "Add location")}
        <% end %>
      </:header>

      <.form
        for={@form}
        id="venue-form"
        phx-change="validate_venue"
        phx-submit="save_venue"
        phx-target={@myself}
        class="space-y-4"
      >
        <.input
          field={@form[:name]}
          label={dgettext("dashboard_meeting_types", "Name")}
          placeholder={dgettext("dashboard_meeting_types", "e.g., Berlin office")}
          maxlength={VenueSchema.name_max_length()}
          required
        />

        <.input
          field={@form[:description]}
          type="textarea"
          rows={4}
          label={dgettext("dashboard_meeting_types", "Address and directions (optional)")}
          maxlength={VenueSchema.description_max_length()}
        >
          <:description>
            {dgettext(
              "dashboard_meeting_types",
              "Street, postcode and city, plus anything that helps bookers find you: 3rd floor, ring the bell."
            )}
          </:description>
        </.input>

        <div class="flex justify-end gap-2 pt-2">
          <.action_button
            type="button"
            variant={:secondary}
            phx-click="close_venue_form"
            phx-target={@myself}
          >
            {dgettext("dashboard_meeting_types", "Cancel")}
          </.action_button>
          <.action_button type="submit" variant={:primary}>
            {dgettext("dashboard_meeting_types", "Save location")}
          </.action_button>
        </div>
      </.form>
    </.modal>
    """
  end
end
