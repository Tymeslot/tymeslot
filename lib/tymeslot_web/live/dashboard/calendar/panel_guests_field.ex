defmodule TymeslotWeb.Dashboard.Calendar.PanelGuestsField do
  @moduledoc """
  The side panel's Guests row: a row per guest with their answer
  (`GuestReplies`, `GuestStatusPill`) and a remove button, and an email
  field with Invite. In the edit mode (`guests_row/1`) both act at
  once, emailing the guest concerned (`PanelGuests`); in the new-event mode
  (`draft_guests/1`) they only change the draft, and nobody is emailed until
  "Create and invite". On an event someone else organises the edit mode
  lists the guests without either control, since both email them. Also the
  "Guests haven't been told" note (`untold_note/1`) the panel shows below
  its header.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CalendarGrid.GuestReplies
  alias TymeslotWeb.Components.Dashboard.Meetings.GuestStatusPill
  alias TymeslotWeb.Dashboard.Calendar.PanelGuests

  attr :guests, :list, required: true, doc: "normalised attendees"
  attr :form_key, :integer, required: true
  attr :repeating, :boolean, default: false
  attr :organiser, :boolean, default: true, doc: "whether the user may email the guests"
  attr :surface, :any, required: true

  @spec guests_row(map()) :: Phoenix.LiveView.Rendered.t()
  def guests_row(assigns) do
    assigns =
      assign(
        assigns,
        :rows,
        Enum.map(assigns.guests, &{&1, GuestReplies.reply(&1.response_status)})
      )

    ~H"""
    <section id="calendar-panel-guests" class="space-y-2">
      <h3 class="label mb-0">
        {dgettext("dashboard_calendar_editing", "Guests")}
      </h3>
      <ul :if={@guests != []} id="calendar-panel-guest-list" class="space-y-1">
        <li
          :for={{guest, reply} <- @rows}
          class="flex min-h-11 items-center gap-2 text-token-sm text-tymeslot-800 sm:min-h-8"
        >
          <span class="min-w-0 flex-1 truncate">{guest.display_name || guest.email}</span>
          <GuestStatusPill.guest_status_pill :if={reply} status={reply} />
          <button
            :if={@organiser}
            type="button"
            phx-click="panel:guest_remove"
            phx-value-email={guest.email}
            phx-target={@surface}
            aria-label={
              dgettext("dashboard_calendar_editing", "Remove %{guest}",
                guest: guest.display_name || guest.email
              )
            }
            class="shrink-0 rounded-token-full p-0.5 text-tymeslot-500 hover:bg-tymeslot-200 hover:text-tymeslot-800 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-turquoise-400"
          >
            <.icon name="hero-x-mark-micro" class="h-4 w-4" />
          </button>
        </li>
      </ul>
      <form
        :if={@organiser}
        novalidate
        id="calendar-panel-guest-form"
        class="flex items-end gap-2"
        phx-submit="panel:guest_invite"
        phx-target={@surface}
      >
        <div class="min-w-0 flex-1">
          <.input
            type="email"
            id={"calendar-panel-guest-email-#{@form_key}"}
            name="email"
            value=""
            label={dgettext("dashboard_calendar_editing", "Invite a guest")}
            placeholder={dgettext("dashboard_calendar_editing", "name@example.com")}
          />
        </div>
        <.action_button id="calendar-panel-guest-invite" type="submit" variant={:secondary} size={:sm}>
          {dgettext("dashboard_calendar_editing", "Invite")}
        </.action_button>
      </form>
      <p
        :if={!@organiser}
        id="calendar-panel-guests-not-organiser"
        class="text-token-xs text-tymeslot-500"
      >
        {PanelGuests.not_organiser_message()}
      </p>
      <p :if={@organiser} class="text-token-xs text-tymeslot-500">
        {dgettext("dashboard_calendar_editing", "Invite emails them now.")}
        <span :if={@repeating}>
          {dgettext("dashboard_calendar_editing", "Guests change for this event only.")}
        </span>
      </p>
    </section>
    """
  end

  attr :guests, :list, required: true, doc: "email strings"
  attr :form_key, :integer, required: true
  attr :surface, :any, required: true

  @spec draft_guests(map()) :: Phoenix.LiveView.Rendered.t()
  def draft_guests(assigns) do
    ~H"""
    <section id="calendar-panel-guests" class="space-y-2">
      <h3 class="label mb-0">
        {dgettext("dashboard_calendar_editing", "Guests")}
      </h3>
      <ul :if={@guests != []} class="flex flex-wrap gap-1.5">
        <li
          :for={email <- @guests}
          class="inline-flex max-w-full items-center gap-1 rounded-token-full bg-tymeslot-100 py-0.5 pl-2.5 pr-1 text-token-sm text-tymeslot-800"
        >
          <input type="hidden" name="guests[]" value={email} />
          <span class="truncate">{email}</span>
          <button
            type="button"
            phx-click={JS.push("panel:draft_drop_guest", value: %{email: email}, target: @surface)}
            aria-label={dgettext("dashboard_calendar_editing", "Remove %{guest}", guest: email)}
            class="shrink-0 rounded-token-full p-0.5 text-tymeslot-500 hover:bg-tymeslot-200 hover:text-tymeslot-800 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-turquoise-400"
          >
            <.icon name="hero-x-mark-micro" class="h-4 w-4" />
          </button>
        </li>
      </ul>
      <div class="flex items-end gap-2">
        <div class="min-w-0 flex-1">
          <.input
            type="email"
            id={"calendar-panel-guest-email-#{@form_key}"}
            name="guest_email"
            value=""
            label={dgettext("dashboard_calendar_editing", "Add a guest")}
            placeholder={dgettext("dashboard_calendar_editing", "name@example.com")}
          />
        </div>
        <.action_button
          id="calendar-panel-guest-add"
          type="submit"
          name="intent"
          value="add_guest"
          variant={:secondary}
          size={:sm}
        >
          {dgettext("dashboard_calendar_editing", "Add")}
        </.action_button>
      </div>
      <p :if={@guests != []} class="text-token-xs text-tymeslot-500">
        {dgettext("dashboard_calendar_editing", "They'll be invited when you create the event.")}
      </p>
    </section>
    """
  end

  attr :saving, :boolean, required: true
  attr :surface, :any, required: true

  @spec untold_note(map()) :: Phoenix.LiveView.Rendered.t()
  def untold_note(assigns) do
    ~H"""
    <div
      id="calendar-panel-untold"
      class="flex flex-wrap items-center gap-2 rounded-token-lg bg-amber-50 px-3 py-2 text-token-sm text-amber-900"
    >
      <span class="min-w-0 flex-1">
        {dgettext("dashboard_calendar_editing", "Guests haven't been told about these changes")}
      </span>
      <.action_button
        id="calendar-panel-tell-guests"
        variant={:secondary}
        size={:sm}
        disabled={@saving}
        phx-click="panel:tell_guests"
        phx-target={@surface}
      >
        {dgettext("dashboard_calendar_editing", "Tell guests")}
      </.action_button>
    </div>
    """
  end
end
