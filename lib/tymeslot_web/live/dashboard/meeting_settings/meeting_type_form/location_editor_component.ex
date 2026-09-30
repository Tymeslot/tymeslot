defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.LocationEditorComponent do
  @moduledoc """
  Modal editor for a single `LocationOption`. Owns a private Ecto changeset
  over the location being created or updated.

  On a valid save, the component merges the updated location into the
  existing `locations` list and pushes `locations` and
  `editing_location: nil` into the parent `MeetingTypeForm` via
  `Phoenix.LiveView.send_update/2`, the same single-hop round-trip
  `QuestionEditorComponent` uses, which keeps `LiveViewTest` helpers
  deterministic.

  An in-person location picks from the organiser's saved venues
  (`VenuePicker`). "+ New location" opens `NewVenueComponent` below the
  form; it saves the venue and sends it back here as `venue_created`, which
  adds it to the choices and ticks it without leaving the editor. The inline
  form is a sibling of this component's `<form>`, never nested in it, so the
  Save button sits after both and names its form explicitly.

  The venue list itself belongs to the meeting settings page
  (`parent_myself`), which loads it with the rest of its data and hands it
  down. A new venue therefore also asks that page to reload, or its next
  render would hand down the list from before the venue existed and the
  meeting type would lose it on the following save. Because the page can
  re-render this editor at any time, an update keeps the changeset for as
  long as it is the same location being edited.

  The `mode` assign (`:add` or `:edit`) controls the modal header. It is set
  by `LocationsSection` and forwarded through `MeetingTypeForm`; do not
  derive it from `@location.id`, which is always populated.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Phoenix.LiveView
  alias Phoenix.LiveView.JS
  alias Tymeslot.MeetingTypes.LocationOption
  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Components.CoreComponents.Forms
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.NewVenueComponent
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.VenuePicker
  alias TymeslotWeb.Helpers.LocationIcons
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  import TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.ChoiceToggle,
    only: [choice_toggle: 1]

  @allowed_error_fields ~w(label details video_integration_ids venue_ids)

  # Multi-select pickers post a leading blank (see `ChoiceToggle`).
  @id_list_fields ~w(video_integration_ids venue_ids)

  # A venue made with "+ New location" joins the choices and is ticked, on
  # top of whatever the organiser has already ticked or typed. A new venue is
  # last in the organiser's order, so it is appended, as it is in the
  # library, and ticked last.
  @impl Phoenix.LiveComponent
  def update(%{venue_created: venue}, socket) do
    changeset = socket.assigns.changeset
    ids = (Changeset.get_field(changeset, :venue_ids) || []) ++ [venue.id]
    params = Map.put(changeset.params || %{}, "venue_ids", Enum.map(ids, &to_string/1))
    venues = socket.assigns.venues ++ [venue]

    LiveView.send_update(socket.assigns.parent_myself, %{})

    {:ok,
     socket
     |> assign(:venues, venues)
     |> assign(:changeset, LocationOption.changeset(socket.assigns.location, params))
     |> assign(:creating_venue, false)}
  end

  def update(assigns, socket) do
    socket = assign(socket, assigns)
    location = socket.assigns[:location] || %LocationOption{}

    {:ok,
     socket
     |> assign(:location, location)
     |> start_changeset(location)
     |> assign_new(:venues, fn -> [] end)
     |> assign_new(:mode, fn -> :add end)
     |> assign_new(:field_errors, fn -> %{} end)
     |> assign_new(:creating_venue, fn -> false end)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("validate", %{"location" => params} = event_params, socket) do
    params =
      params
      |> normalise_id_lists()
      |> default_label_for_kind(socket.assigns.changeset)

    field_errors =
      FormValidationHelpers.clear_target_error(
        socket.assigns.field_errors,
        event_params["_target"],
        @allowed_error_fields
      )

    {:noreply,
     socket
     |> assign(:changeset, LocationOption.changeset(socket.assigns.location, params))
     |> assign(:field_errors, field_errors)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("save", %{"location" => params}, socket) do
    changeset = LocationOption.changeset(socket.assigns.location, normalise_id_lists(params))

    if changeset.valid? do
      location = Changeset.apply_changes(changeset)
      existing = socket.assigns.existing_locations || []

      updated =
        if Enum.any?(existing, &(&1.id == location.id)) do
          Enum.map(existing, fn l -> if l.id == location.id, do: location, else: l end)
        else
          existing ++ [location]
        end

      LiveView.send_update(MeetingTypeForm,
        id: socket.assigns.form_id,
        locations: updated,
        editing_location: nil
      )

      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:changeset, changeset)
       |> assign(:field_errors, FormValidationHelpers.changeset_errors_map(changeset))}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("cancel", _params, socket) do
    LiveView.send_update(MeetingTypeForm,
      id: socket.assigns.form_id,
      editing_location: nil
    )

    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("toggle_new_venue", _params, socket) do
    {:noreply, assign(socket, :creating_venue, !socket.assigns.creating_venue)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("field_blur", %{"field" => field}, socket)
      when field in @allowed_error_fields do
    field_errors =
      FormValidationHelpers.sync_changeset_field_error(
        socket.assigns.field_errors,
        socket.assigns.changeset,
        String.to_existing_atom(field)
      )

    {:noreply, assign(socket, :field_errors, field_errors)}
  end

  def handle_event("field_blur", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={"location-editor-wrapper-#{@id}"}>
      <CoreComponents.modal
        id={"location-editor-#{@id}"}
        show
        on_cancel={JS.push("cancel", target: @myself)}
        size={:medium}
      >
        <:header>
          <%= if @mode == :edit do %>
            {dgettext("dashboard_meeting_form", "Edit location")}
          <% else %>
            {dgettext("dashboard_meeting_form", "Add location")}
          <% end %>
        </:header>

        <.form
          for={@changeset}
          as={:location}
          id="location-editor-form"
          phx-change="validate"
          phx-submit="save"
          phx-target={@myself}
          class="space-y-4"
        >
          <.choice_toggle
            id="location_kind"
            name="location[kind]"
            value={field_value(@changeset, :kind)}
            label={dgettext("dashboard_meeting_form", "Type")}
            options={kind_options()}
          >
            <:description>
              {dgettext("dashboard_meeting_form", "Decides what happens when a booker picks this.")}
            </:description>
          </.choice_toggle>

          <CoreComponents.input
            name="location[label]"
            value={field_value(@changeset, :label)}
            id="location_label"
            type="text"
            label={dgettext("dashboard_meeting_form", "Label")}
            placeholder={dgettext("dashboard_meeting_form", "e.g., Our London office")}
            required
            phx-blur="field_blur"
            phx-value-field="label"
            phx-target={@myself}
            errors={FormValidationHelpers.field_errors(@field_errors, :label)}
          >
            <:description>
              {dgettext("dashboard_meeting_form", "What the booker sees in the list of locations.")}
            </:description>
          </CoreComponents.input>

          <%= case field_value(@changeset, :kind) do %>
            <% "video" -> %>
              <.video_integration_picker
                changeset={@changeset}
                video_integrations={@video_integrations}
                field_errors={@field_errors}
                myself={@myself}
              />
            <% "in_person" -> %>
              <VenuePicker.venue_picker
                changeset={@changeset}
                venues={@venues}
                field_errors={@field_errors}
                myself={@myself}
              />
            <% "phone" -> %>
              <CoreComponents.input
                name="location[collect_from_guest]"
                value={field_value(@changeset, :collect_from_guest)}
                id="location_collect_from_guest"
                type="checkbox"
                label={dgettext("dashboard_meeting_form", "Ask the booker for their number")}
              >
                <:description>
                  {dgettext(
                    "dashboard_meeting_form",
                    "You call them. Leave this off to publish a number for them to call instead."
                  )}
                </:description>
              </CoreComponents.input>

              <CoreComponents.input
                :if={!field_value(@changeset, :collect_from_guest)}
                name="location[details]"
                value={field_value(@changeset, :details)}
                id="location_details"
                type="text"
                label={dgettext("dashboard_meeting_form", "Number to call")}
                placeholder="+44 20 7946 0000"
                required
                phx-blur="field_blur"
                phx-value-field="details"
                phx-target={@myself}
                errors={FormValidationHelpers.field_errors(@field_errors, :details)}
              />
            <% _kind -> %>
              <CoreComponents.input
                name="location[details]"
                value={field_value(@changeset, :details)}
                id="location_details"
                type="textarea"
                label={dgettext("dashboard_meeting_form", "Details (optional)")}
                placeholder={
                  dgettext(
                    "dashboard_meeting_form",
                    "Anything the booker needs to know to get there"
                  )
                }
                rows={3}
                phx-blur="field_blur"
                phx-value-field="details"
                phx-target={@myself}
                errors={FormValidationHelpers.field_errors(@field_errors, :details)}
              >
                <:description>
                  {dgettext(
                    "dashboard_meeting_form",
                    "Shown to the booker and written into the calendar invitation."
                  )}
                </:description>
              </CoreComponents.input>
          <% end %>

          <%!-- Position travels with the option so a save from the editor
                cannot reset the order the host dragged it into. --%>
          <input type="hidden" name="location[id]" value={field_value(@changeset, :id)} />
          <input
            type="hidden"
            name="location[position]"
            value={field_value(@changeset, :position)}
          />
        </.form>

        <%!-- Outside the form above: HTML forms cannot nest. --%>
        <.live_component
          :if={@creating_venue and field_value(@changeset, :kind) == "in_person"}
          module={NewVenueComponent}
          id={"new-venue-#{@id}"}
          editor_id={@id}
          editor={@myself}
          current_user={@current_user}
        />

        <div class="flex justify-end gap-2 pt-4">
          <CoreComponents.action_button
            type="button"
            variant={:secondary}
            phx-click="cancel"
            phx-target={@myself}
          >
            {dgettext("dashboard_meeting_form", "Cancel")}
          </CoreComponents.action_button>
          <CoreComponents.action_button
            type="submit"
            form="location-editor-form"
            variant={:primary}
          >
            {dgettext("dashboard_meeting_form", "Save location")}
          </CoreComponents.action_button>
        </div>
      </CoreComponents.modal>
    </div>
    """
  end

  attr :changeset, :any, required: true
  attr :video_integrations, :list, required: true
  attr :field_errors, :map, required: true
  attr :myself, :any, required: true

  defp video_integration_picker(assigns) do
    ~H"""
    <div>
      <%= if @video_integrations == [] do %>
        <Forms.label>
          {dgettext("dashboard_meeting_form", "Video provider")}
          <span class="text-red-500 ml-0.5">*</span>
        </Forms.label>
        <div class="p-4 bg-yellow-500/10 border border-yellow-500/30 rounded-token-lg">
          <p class="text-token-sm text-yellow-700">
            {dgettext("dashboard_meeting_form", "No video integrations configured.")}
            <a href={~p"/dashboard/integrations?tab=video"} class="underline hover:text-yellow-800">
              {dgettext("dashboard_meeting_form", "Set up video integration")}
            </a>
          </p>
        </div>
      <% else %>
        <.choice_toggle
          id="location_video_integration_ids"
          name="location[video_integration_ids][]"
          value={field_value(@changeset, :video_integration_ids)}
          label={dgettext("dashboard_meeting_form", "Video providers")}
          options={integration_options(@video_integrations)}
          multiple
          required
          errors={FormValidationHelpers.field_errors(@field_errors, :video_integration_ids)}
        >
          <:description>
            {dgettext(
              "dashboard_meeting_form",
              "Pick one or more. With several, the booker chooses which one the room is created on."
            )}
          </:description>
        </.choice_toggle>
      <% end %>
    </div>
    """
  end

  # A fresh changeset only for a location not already being edited: a
  # re-render from the page above must not discard what has been ticked or
  # typed so far.
  defp start_changeset(socket, %LocationOption{id: id} = location) do
    case socket.assigns[:changeset] do
      %Changeset{data: %LocationOption{id: ^id}} -> socket
      _other -> assign(socket, :changeset, LocationOption.changeset(location, %{}))
    end
  end

  defp normalise_id_lists(params) do
    Enum.reduce(@id_list_fields, params, fn field, acc ->
      case acc do
        %{^field => ids} when is_list(ids) -> Map.put(acc, field, Enum.reject(ids, &(&1 == "")))
        _other -> acc
      end
    end)
  end

  # A location's label is the one field the host must write, and every kind
  # has an obvious name for itself. Filling it in when the kind changes on a
  # still-unnamed option means "add location, choose Zoom, save" works, while
  # a label the host has already typed is never overwritten.
  defp default_label_for_kind(params, changeset) do
    current = Changeset.get_field(changeset, :label)

    if blank?(params["label"]) and blank?(current) do
      Map.put(params, "label", default_label(params["kind"]))
    else
      params
    end
  end

  defp blank?(value), do: value in [nil, ""]

  defp default_label("video"), do: dgettext("dashboard_meeting_form", "Video call")
  defp default_label("phone"), do: dgettext("dashboard_meeting_form", "Phone call")
  defp default_label("in_person"), do: dgettext("dashboard_meeting_form", "In person")
  defp default_label(_kind), do: dgettext("dashboard_meeting_form", "Somewhere else")

  # A pill shows the integration's name, with the account in its tooltip. Two
  # integrations sharing a name (two Zoom accounts, say) would be two
  # identical pills, so those carry the account on the pill itself.
  defp integration_options(integrations) do
    shared_names =
      integrations
      |> Enum.frequencies_by(& &1.name)
      |> Enum.flat_map(fn {name, count} -> if count > 1, do: [name], else: [] end)

    Enum.map(integrations, fn integration ->
      %{
        value: integration.id,
        label: integration_label(integration, integration.name in shared_names),
        icon: LocationIcons.icon("video"),
        title: integration.provider_account_email
      }
    end)
  end

  defp integration_label(%{name: name, provider_account_email: email}, true)
       when is_binary(email) and email != "",
       do: "#{name} (#{email})"

  defp integration_label(%{name: name}, _shared?), do: name

  defp kind_options do
    for {label, kind} <- [
          {dgettext("dashboard_meeting_form", "In person"), "in_person"},
          {dgettext("dashboard_meeting_form", "Video call"), "video"},
          {dgettext("dashboard_meeting_form", "Phone call"), "phone"},
          {dgettext("dashboard_meeting_form", "Something else"), "custom"}
        ] do
      %{value: kind, label: label, icon: LocationIcons.icon(kind)}
    end
  end

  defp field_value(changeset, field), do: Changeset.get_field(changeset, field)
end
