defmodule TymeslotWeb.Dashboard.MeetingSettings.InvitationsComponent do
  @moduledoc """
  The invitation links of an invitation-only meeting type, shown in the
  meeting type editor in place of its direct booking link.

  The host creates one single-use link at a time and sends it themselves:
  Tymeslot sends no email. Below the form, the type's invitations, newest
  first, each with its derived status (`Tymeslot.Invitations.list/2`) and the
  actions that status allows: copy and revoke an available link, reopen a
  used one whose appointment no longer holds a slot, or a revoked one that
  has not expired since.

  Every action is scoped to the host (`current_user_id`), and the list is
  reloaded from the context after each, so a status is never patched here.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Clock
  alias Tymeslot.Invitations
  alias Tymeslot.Invitations.InvitationStatus
  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Components.CoreComponents.Feedback
  alias TymeslotWeb.Dashboard.DashboardFormat
  alias TymeslotWeb.Dashboard.MeetingSettings.RevokeInvitationModal
  alias TymeslotWeb.Endpoint

  # The list is unbounded; the newest this many are shown. The note under a
  # truncated list states the number in its text, so change both together.
  @shown 100

  # Changeset fields the form shows under a field of another name.
  @form_fields %{expires_at: :expires_on}

  # The changeset fields the form has an input for.
  @shown_fields [:name, :email, :expires_on]

  @blank_params %{"name" => "", "email" => "", "expires_on" => "", "release_on_cancel" => "true"}

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> assign(created_id: nil, revoke_id: nil, form_error: nil, entries: nil)
     |> assign_form(@blank_params)}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    reload? = socket.assigns.entries == nil or type_changed?(socket, assigns)
    socket = assign(socket, assigns)

    {:ok, if(reload?, do: load_entries(socket), else: socket)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("change", %{"invitation" => params}, socket) when is_map(params),
    do: {:noreply, assign_form(socket, params)}

  # The switch sends a click, not a form value: the hidden input carries it.
  def handle_event("toggle_release", _params, socket) do
    params = Map.update(socket.assigns.form.params, "release_on_cancel", "false", &flip/1)
    {:noreply, assign_form(socket, params)}
  end

  def handle_event("create", %{"invitation" => params}, socket) when is_map(params) do
    %{current_user_id: user_id, meeting_type: type} = socket.assigns

    case Invitations.create(user_id, type, create_attrs(params, timezone(socket.assigns))) do
      {:ok, invitation} ->
        {:noreply,
         socket
         |> assign(created_id: invitation.id, form_error: nil)
         |> assign_form(@blank_params)
         |> load_entries()}

      {:error, :rate_limited, message} ->
        {:noreply, socket |> assign(form_error: message) |> assign_form(params)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(form_error: unshown_error(changeset))
         |> assign_form(params, changeset)}

      {:error, _not_found_or_not_invitation_only} ->
        Flash.error(
          dgettext("dashboard_meeting_types", "Invitation links are off for this type.")
        )

        {:noreply, socket}
    end
  end

  def handle_event("ask_revoke", %{"id" => id}, socket),
    do: {:noreply, assign(socket, :revoke_id, id)}

  def handle_event("cancel_revoke", _params, socket),
    do: {:noreply, assign(socket, :revoke_id, nil)}

  def handle_event("revoke", %{"id" => id}, socket) do
    socket = assign(socket, :revoke_id, nil)

    with_id(id, socket, fn invitation_id ->
      Invitations.revoke(socket.assigns.current_user_id, invitation_id)
    end)
  end

  def handle_event("reopen", %{"id" => id}, socket) do
    with_id(id, socket, fn invitation_id ->
      Invitations.reopen(socket.assigns.current_user_id, invitation_id)
    end)
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Runs a host-scoped action on the invitation `id` names, then reloads the
  # list. An id that is not one of the host's changes nothing.
  defp with_id(id, socket, action) do
    with {invitation_id, ""} <- Integer.parse(to_string(id)),
         {:ok, _invitation} <- action.(invitation_id) do
      {:noreply, load_entries(socket)}
    else
      {:error, :expired} ->
        Flash.error(
          dgettext(
            "dashboard_meeting_types",
            "This link has expired, so it can't be reopened. Create a new one instead."
          )
        )

        {:noreply, load_entries(socket)}

      _refused ->
        Flash.error(dgettext("dashboard_meeting_types", "That invitation can't be changed."))
        {:noreply, load_entries(socket)}
    end
  end

  defp type_changed?(socket, %{meeting_type: %{id: id}}),
    do: socket.assigns[:meeting_type] && socket.assigns.meeting_type.id != id

  defp type_changed?(_socket, _assigns), do: false

  defp load_entries(socket) do
    %{current_user_id: user_id, meeting_type: type} = socket.assigns
    entries = Invitations.list(user_id, type, limit: @shown + 1)

    assign(socket,
      entries: Enum.take(entries, @shown),
      more?: length(entries) > @shown
    )
  end

  defp assign_form(socket, params, changeset \\ nil) do
    errors =
      if changeset,
        do: Enum.map(changeset.errors, fn {field, error} -> {form_field(field), error} end),
        else: []

    assign(socket, :form, to_form(params, as: :invitation, errors: errors))
  end

  defp form_field(field), do: Map.get(@form_fields, field, field)

  # An error on a field the form has no input for would otherwise vanish.
  defp unshown_error(changeset) do
    if Enum.all?(changeset.errors, fn {field, _error} -> form_field(field) in @shown_fields end),
      do: nil,
      else: dgettext("dashboard_meeting_types", "Could not create the invitation link.")
  end

  defp flip("false"), do: "true"
  defp flip(_on), do: "false"

  defp create_attrs(params, timezone) do
    %{
      name: params["name"],
      email: params["email"],
      expires_at: expires_at(params["expires_on"], timezone),
      release_on_cancel: params["release_on_cancel"] != "false"
    }
  end

  # The link lasts to the end of the chosen day where the host lives.
  defp expires_at(value, timezone) when is_binary(value) and value != "" do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        date
        |> DateTimeUtils.create_datetime_safe(~T[23:59:59], timezone)
        |> DateTime.shift_zone!("Etc/UTC")

      {:error, _invalid} ->
        value
    end
  end

  defp expires_at(_blank, _timezone), do: nil

  defp timezone(%{profile: %{timezone: timezone}}) when is_binary(timezone), do: timezone
  defp timezone(_assigns), do: "Etc/UTC"

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns = assign(assigns, timezone: timezone(assigns))

    ~H"""
    <section id={@id} class="space-y-4" data-testid="invitations-panel">
      <div class="space-y-1">
        <.subsection_header
          icon="hero-envelope"
          title={dgettext("dashboard_meeting_types", "Invitation links")}
        />
        <p class="text-token-sm text-tymeslot-500">
          {dgettext(
            "dashboard_meeting_types",
            "Each link books one appointment. Tymeslot sends no email: copy the link and send it yourself."
          )}
        </p>
      </div>

      <.form
        for={@form}
        id={"#{@id}-form"}
        phx-change="change"
        phx-submit="create"
        phx-target={@myself}
        class="space-y-4"
        novalidate
      >
        <div class="grid gap-4 sm:grid-cols-3">
          <.input
            field={@form[:name]}
            label={dgettext("dashboard_meeting_types", "Name (optional)")}
            maxlength="255"
          />
          <.input
            field={@form[:email]}
            type="email"
            label={dgettext("dashboard_meeting_types", "Email (optional)")}
          />
          <.date_picker
            field={@form[:expires_on]}
            label={dgettext("dashboard_meeting_types", "Link expires on (optional)")}
            min={Date.to_iso8601(today(@timezone))}
          />
        </div>
        <input
          type="hidden"
          name={@form[:release_on_cancel].name}
          value={@form[:release_on_cancel].value}
        />
        <.setting_row
          id={"#{@id}-release-on-cancel"}
          control={:switch}
          label={dgettext("dashboard_meeting_types", "Reusable after cancellation")}
          description={
            dgettext(
              "dashboard_meeting_types",
              "If the appointment is cancelled, the link can be used again."
            )
          }
          checked={@form[:release_on_cancel].value != "false"}
          on_change="toggle_release"
          target={@myself}
        />
        <p :if={@form_error} class="form-error" role="alert" data-testid="invitation-form-error">
          {@form_error}
        </p>
        <.action_button type="submit" icon="hero-plus">
          {dgettext("dashboard_meeting_types", "Create invitation link")}
        </.action_button>
      </.form>

      <.empty_state
        :if={@entries == []}
        icon="hero-envelope"
        size={:sm}
        variant={:dashed}
        title={
          dgettext(
            "dashboard_meeting_types",
            "No invitations yet. Create one link per person you want to invite."
          )
        }
      />

      <ul :if={@entries != []} class="space-y-2" data-testid="invitations-list">
        <li
          :for={entry <- @entries}
          id={"invitation-#{entry.invitation.id}"}
          data-status={entry.status}
          class={[
            "flex flex-wrap items-center gap-3 rounded-token-xl border-2 px-4 py-3",
            if(entry.invitation.id == @created_id,
              do: "border-turquoise-300 bg-turquoise-50",
              else: "border-tymeslot-100 bg-white"
            )
          ]}
        >
          <div class="flex-1 min-w-[12rem] space-y-1">
            <div class="flex flex-wrap items-center gap-2">
              <span class="font-medium text-tymeslot-900 truncate">
                {invitee(entry.invitation)}
              </span>
              <.status_pill status={entry.status} />
            </div>
            <p class="text-token-sm text-tymeslot-500 space-x-2">
              <span :if={entry.invitation.name && entry.invitation.email}>
                {entry.invitation.email}
              </span>
              <span :if={entry.status == :used} data-testid="invitation-booked-at">
                {dgettext("dashboard_meeting_types", "Booked for %{time}",
                  time: when_label(entry.meeting.start_time, @timezone, @time_format)
                )}
              </span>
              <span
                :if={entry.status == :used and reopenable?(entry)}
                data-testid="invitation-cancelled"
              >
                {dgettext("dashboard_meeting_types", "Appointment cancelled")}
              </span>
              <span :if={booked_as(entry)} data-testid="invitation-booked-as">
                {dgettext("dashboard_meeting_types", "Booked as %{email}", email: booked_as(entry))}
              </span>
              <span :if={entry.invitation.expires_at} data-testid="invitation-expiry">
                {dgettext("dashboard_meeting_types", "Expires %{date}",
                  date: expiry_label(entry.invitation.expires_at, @timezone)
                )}
              </span>
            </p>
          </div>
          <div class="flex items-center gap-2 shrink-0">
            <.action_button
              :if={entry.status == :available and is_binary(entry.invitation.token)}
              variant={:secondary}
              size={:sm}
              icon="hero-link"
              id={"copy-invitation-#{entry.invitation.id}"}
              phx-hook="CopyOnClick"
              data-copy-text={invite_url(entry.invitation)}
              aria-label={link_label(:copy, entry.invitation)}
              data-copy-feedback={dgettext("dashboard_meeting_types", "Invitation link copied!")}
            >
              {dgettext("dashboard_meeting_types", "Copy link")}
            </.action_button>
            <.action_button
              :if={entry.status == :available}
              variant={:danger_soft}
              size={:sm}
              phx-click="ask_revoke"
              phx-value-id={entry.invitation.id}
              phx-target={@myself}
              aria-label={link_label(:revoke, entry.invitation)}
            >
              {dgettext("dashboard_meeting_types", "Revoke")}
            </.action_button>
            <.action_button
              :if={reopenable?(entry)}
              variant={:secondary}
              size={:sm}
              icon="hero-arrow-path"
              phx-click="reopen"
              phx-value-id={entry.invitation.id}
              phx-target={@myself}
              aria-label={link_label(:reopen, entry.invitation)}
            >
              {dgettext("dashboard_meeting_types", "Reopen")}
            </.action_button>
          </div>
          <p
            :if={entry.status == :available and not is_binary(entry.invitation.token)}
            class="basis-full text-token-sm text-tymeslot-600"
            data-testid="invitation-token-unavailable"
          >
            {dgettext(
              "dashboard_meeting_types",
              "This link can't be shown. Revoke it and create a new one."
            )}
          </p>
        </li>
      </ul>

      <p :if={@more?} class="text-token-sm text-tymeslot-500" data-testid="invitations-truncated">
        {dgettext("dashboard_meeting_types", "Showing the latest 100 invitations.")}
      </p>

      <RevokeInvitationModal.revoke_invitation_modal
        id={"#{@id}-revoke-modal"}
        invitation_id={@revoke_id}
        myself={@myself}
      />
    </section>
    """
  end

  attr :status, :atom, required: true

  defp status_pill(assigns) do
    ~H"""
    <Feedback.pill tone={status_tone(@status)} uppercase data-testid="invitation-status">
      {status_label(@status)}
    </Feedback.pill>
    """
  end

  defp status_tone(:available), do: :brand
  defp status_tone(:used), do: :info
  defp status_tone(:expired), do: :warning
  defp status_tone(:revoked), do: :neutral

  defp status_label(:available), do: dgettext("dashboard_meeting_types", "Available")
  defp status_label(:used), do: dgettext("dashboard_meeting_types", "Used")
  defp status_label(:expired), do: dgettext("dashboard_meeting_types", "Expired")
  defp status_label(:revoked), do: dgettext("dashboard_meeting_types", "Revoked")

  # The name a button's accessible label gives the invitation, if it has one.
  defp link_label(action, invitation) do
    case invitee_name(invitation) do
      nil -> link_label(action)
      name -> named_link_label(action, name)
    end
  end

  defp link_label(:copy), do: dgettext("dashboard_meeting_types", "Copy link")
  defp link_label(:revoke), do: dgettext("dashboard_meeting_types", "Revoke link")
  defp link_label(:reopen), do: dgettext("dashboard_meeting_types", "Reopen link")

  defp named_link_label(:copy, name),
    do: dgettext("dashboard_meeting_types", "Copy link for %{name}", name: name)

  defp named_link_label(:revoke, name),
    do: dgettext("dashboard_meeting_types", "Revoke link for %{name}", name: name)

  defp named_link_label(:reopen, name),
    do: dgettext("dashboard_meeting_types", "Reopen link for %{name}", name: name)

  defp invitee_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp invitee_name(%{email: email}) when is_binary(email) and email != "", do: email
  defp invitee_name(_unnamed), do: nil

  defp invitee(%{name: name}) when is_binary(name) and name != "", do: name
  defp invitee(%{email: email}) when is_binary(email) and email != "", do: email
  defp invitee(_unnamed), do: dgettext("dashboard_meeting_types", "Unnamed invitation")

  # The address the appointment was booked under, when it is not the one the
  # invitation named.
  defp booked_as(%{status: :used, meeting: %{attendee_email: booked}, invitation: invitation})
       when is_binary(booked) do
    if normalise(booked) != normalise(invitation.email), do: booked
  end

  defp booked_as(_entry), do: nil

  defp normalise(nil), do: nil
  defp normalise(email), do: email |> String.trim() |> String.downcase()

  # A used link whose appointment no longer holds a slot, or a revoked one
  # that has not expired meanwhile: reopening that would only make it expired.
  # The context refuses that reopen with `{:error, :expired}`.
  defp reopenable?(%{status: :revoked, invitation: invitation}),
    do: not InvitationStatus.expired?(invitation, Clock.utc_now())

  defp reopenable?(%{status: :used, invitation: invitation, meeting: meeting}),
    do: InvitationStatus.reopenable?(invitation, meeting)

  defp reopenable?(_entry), do: false

  # A token that could not be decrypted (nil) offers no link to copy.
  defp invite_url(%{token: token}) when is_binary(token),
    do: Endpoint.url() <> ~p"/invite/#{token}"

  defp when_label(starts_at, timezone, time_format) do
    date = starts_at |> DashboardFormat.local_date(timezone) |> DashboardFormat.long_date()
    "#{date}, #{DashboardFormat.clock(starts_at, timezone, time_format)}"
  end

  defp expiry_label(expires_at, timezone),
    do: expires_at |> DashboardFormat.local_date(timezone) |> DashboardFormat.long_date()

  defp today(timezone), do: DashboardFormat.local_date(Clock.utc_now(), timezone)
end
