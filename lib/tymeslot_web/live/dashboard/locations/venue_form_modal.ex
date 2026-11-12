defmodule TymeslotWeb.Dashboard.Locations.VenueFormModal do
  @moduledoc """
  The add and edit modal on the Locations page: a name and a free-text
  address. Its events go to the owning `LocationsComponent` (`@myself`),
  which validates and saves through `Tymeslot.Venues`.

  Editing a saved venue with a translation language, the form sits under the
  language bar, and a translation language swaps it for the translation
  editor (`TymeslotWeb.Dashboard.Languages.TranslatableForm`).
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.Venues.VenueSchema
  alias TymeslotWeb.Dashboard.Languages.TranslatableForm

  attr :form, Phoenix.HTML.Form, required: true
  attr :mode, :atom, required: true, values: [:new, :edit]
  attr :myself, :any, required: true
  attr :venue, VenueSchema, default: nil, doc: "the venue being edited, for its translations"
  attr :profile, :any, default: nil, doc: "for the booking languages"
  attr :editing_locale, :string, default: nil

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
      <:subtitle>
        {dgettext(
          "dashboard_meeting_types",
          "A place you meet people, such as an office or a studio. Offer it on any in-person meeting type, and bookers see its name and address when they book."
        )}
      </:subtitle>

      <%= if @mode == :edit and @profile do %>
        <.live_component
          module={TranslatableForm}
          id={"venue-translations-#{@venue.id}"}
          profile={@profile}
          editing_locale={@editing_locale}
          user_id={@venue.user_id}
          kind={:venue}
          record={@venue}
        >
          <.venue_form form={@form} mode={@mode} myself={@myself} />
          <:actions>
            <div class="flex justify-end pt-2">
              <.action_button
                type="button"
                variant={:secondary}
                phx-click="close_venue_form"
                phx-target={@myself}
              >
                {dgettext("dashboard_meeting_types", "Close")}
              </.action_button>
            </div>
          </:actions>
        </.live_component>
      <% else %>
        <.venue_form form={@form} mode={@mode} myself={@myself} />
      <% end %>
    </.modal>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :mode, :atom, required: true
  attr :myself, :any, required: true

  defp venue_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="venue-form"
      novalidate
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
        phx-hook={@mode == :new && "AutoFocus"}
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
    """
  end
end
