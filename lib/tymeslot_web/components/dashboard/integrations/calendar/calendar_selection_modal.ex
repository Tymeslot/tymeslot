defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.CalendarSelectionModal do
  @moduledoc """
  Modal for managing one connected calendar integration: what it is called,
  what colour its events are shown in, and for each of its calendars whether
  Tymeslot uses it and whether its busy time blocks the booking page.

  Hosts the calendar-selection chip grid that previously lived behind the
  connection row's expand chevron. Surfacing it as an explicit "Manage
  calendars" action keeps the row itself flat.

  Stateless — `show` and the selected integration are owned by the parent
  `CalendarSettingsComponent`. Each control dispatches its event back to
  `@target` (`rename_integration`, `set_integration_colour`,
  `set_calendar_state`, and for an Exchange mailbox's main calendar
  `set_calendar_shown` and `set_calendar_blocking`); the parent
  reloads and re-renders this modal with the updated integration.

  Each calendar is one of:

    * a booking calendar, which always shows and blocks (`Calendar.Blocking`);
    * shared as busy times only, which can be off or block, never shown;
    * an Exchange mailbox's main calendar, whose busy time stands for the
      whole mailbox: whether it blocks is chosen apart from whether it is
      shown, so switching it off never hides that it still blocks;
    * another Exchange folder, which cannot block at all;
    * any other calendar: off, show only, or show and block.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.Blocking
  alias Tymeslot.Integrations.Calendar.DisplayHelpers
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Utils.UriUtils
  alias TymeslotWeb.Components.Dashboard.ColourSwatches

  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :integration, :map, default: nil, doc: "the integration being managed, or nil when closed"

  attr :booking_calendar_ids, :list,
    default: [],
    doc: "ids of the integration's calendars bookings go to, which always block"

  attr :target, :any, required: true
  attr :on_cancel, JS, default: %JS{}

  @spec calendar_selection_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def calendar_selection_modal(assigns) do
    calendar_list = (assigns.integration && assigns.integration.calendar_list) || []
    exchange? = assigns.integration && ProviderConfig.ews?(assigns.integration.provider)
    whole_mailbox? = exchange? && Blocking.mailbox_without_main?(assigns.integration)
    rows = Enum.map(calendar_list, &{&1, kind(&1, exchange?, assigns.booking_calendar_ids)})

    assigns =
      assign(assigns,
        rows: Enum.with_index(rows),
        whole_mailbox?: whole_mailbox?,
        total_count: length(calendar_list),
        used_count: Enum.count(calendar_list, & &1.selected),
        # A mailbox listing no main calendar blocks as one, however many
        # folders it lists.
        blocking_count:
          if(whole_mailbox?,
            do: 1,
            else: Enum.count(calendar_list, &Blocking.blocks?(assigns.integration, &1))
          )
      )

    ~H"""
    <div id={@id}>
      <TymeslotWeb.Components.CoreComponents.Modal.modal
        id={"#{@id}-modal"}
        show={@show}
        on_cancel={@on_cancel}
        size={:medium}
      >
        <%!-- The modal wraps this slot in its own heading, so it takes the
             title text alone: a nested heading is invalid, and the subtitle
             would otherwise land inside the dialog's accessible name. --%>
        <:header>{dgettext("dashboard_calendar_providers", "Manage calendars")}</:header>

        <div :if={@integration}>
          <form
            id={"#{@id}-rename"}
            phx-submit="rename_integration"
            phx-target={@target}
            class="mb-6 flex items-end gap-2"
          >
            <input type="hidden" name="integration_id" value={@integration.id} />
            <div class="flex-1">
              <label for={"#{@id}-name"} class="label">
                {dgettext("dashboard_calendar_providers", "Name")}
              </label>
              <input
                id={"#{@id}-name"}
                type="text"
                name="name"
                value={@integration.name}
                required
                maxlength="100"
                autocomplete="off"
                class="input"
              />
            </div>
            <.action_button type="submit" variant={:secondary}>
              {dgettext("dashboard_calendar_providers", "Rename")}
            </.action_button>
          </form>

          <div class="mb-6">
            <p class="label">
              {dgettext("dashboard_calendar_providers", "Colour")}
            </p>
            <p class="mb-2 text-token-sm text-tymeslot-500">
              {dgettext(
                "dashboard_calendar_providers",
                "How this calendar's events are shown in your Tymeslot calendar."
              )}
            </p>
            <ColourSwatches.colour_swatches
              selected={@integration.colour}
              event="set_integration_colour"
              target={@target}
              group_label={dgettext("dashboard_calendar_providers", "Colour")}
              values={%{"phx-value-integration_id" => @integration.id}}
            />
          </div>

          <p class="mb-4 text-token-sm text-tymeslot-500">
            {dgettext(
              "dashboard_calendar_providers",
              "Choose which calendars Tymeslot uses, and which of them block times on your booking page."
            )}
          </p>

          <div class="mb-3 flex items-center gap-2">
            <span
              id={"#{@id}-count"}
              class="text-token-2xs font-black uppercase tracking-widest text-tymeslot-400"
            >
              {dngettext(
                "dashboard_calendar_providers",
                "%{used} of %{count} calendar in use, %{blocking} blocking your availability",
                "%{used} of %{count} calendars in use, %{blocking} blocking your availability",
                @total_count,
                used: @used_count,
                count: @total_count,
                blocking: @blocking_count
              )}
            </span>
            <div class="h-px flex-1 bg-tymeslot-100"></div>
          </div>

          <div
            :if={@whole_mailbox?}
            id={"#{@id}-mailbox"}
            class="mb-2.5 flex flex-col gap-2 rounded-token-xl border border-tymeslot-100 bg-white px-3.5 py-3"
          >
            <div class="flex flex-wrap items-center justify-between gap-2">
              <span class="text-token-sm font-bold text-tymeslot-800">
                {dgettext("dashboard_calendar_providers", "Whole mailbox")}
              </span>
              <.calendar_badge>
                {dgettext("dashboard_calendar_providers", "Busy times block")}
              </.calendar_badge>
            </div>
            <p class="text-token-xs text-tymeslot-500">
              {dgettext(
                "dashboard_calendar_providers",
                "Exchange reports busy times for your whole mailbox, and they block your booking page. Refresh this connection to list your main calendar and choose there whether they do."
              )}
            </p>
          </div>

          <ul class="flex flex-col gap-2.5">
            <li
              :for={{{calendar, kind}, index} <- @rows}
              id={"#{@id}-calendar-#{index}"}
              data-calendar-id={calendar.id}
              class="flex flex-col gap-2 rounded-token-xl border border-tymeslot-100 bg-white px-3.5 py-3"
            >
              <div class="flex flex-wrap items-center justify-between gap-2">
                <div class="flex min-w-0 flex-wrap items-center gap-2">
                  <div
                    :if={calendar.color}
                    class="h-2.5 w-2.5 shrink-0 rounded-token-full ring-2 ring-white"
                    style={"background-color: #{calendar.color}"}
                  />
                  <span class="truncate text-token-sm font-bold text-tymeslot-800">
                    {DisplayHelpers.extract_calendar_display_name(calendar)}
                  </span>
                  <.calendar_badge :if={calendar.primary}>
                    {dgettext("dashboard_calendar_providers", "Primary")}
                  </.calendar_badge>
                  <.calendar_badge :if={kind == :booking}>
                    {dgettext("dashboard_calendar_providers", "Booking calendar")}
                  </.calendar_badge>
                  <.calendar_badge :if={calendar.free_busy_only}>
                    {dgettext("dashboard_calendar_providers", "Busy times only")}
                  </.calendar_badge>
                  <.calendar_badge :if={calendar.read_only and not calendar.free_busy_only}>
                    {dgettext("dashboard_calendar_providers", "Read-only")}
                  </.calendar_badge>
                </div>

                <.calendar_controls
                  id={"#{@id}-calendar-#{index}"}
                  calendar={calendar}
                  kind={kind}
                  integration_id={@integration.id}
                  target={@target}
                  booking?={booking_calendar?(calendar, @booking_calendar_ids)}
                />
              </div>

              <p :if={helper(kind, @whole_mailbox?)} class="text-token-xs text-tymeslot-500">
                {helper(kind, @whole_mailbox?)}
              </p>
            </li>
          </ul>

          <div class="flex flex-wrap gap-2.5">
            <div :if={@total_count == 0} class="flex items-center gap-2 py-2 text-tymeslot-400">
              <.icon name="hero-information-circle" class="h-4 w-4" />
              <span class="text-token-xs font-medium italic">
                {dgettext(
                  "dashboard_calendar_providers",
                  "No calendars found. Try refreshing the integration."
                )}
              </span>
            </div>
          </div>
        </div>

        <:footer>
          <div class="flex justify-end">
            <.action_button
              variant={:secondary}
              phx-click={@on_cancel}
            >
              {dgettext("dashboard_calendar_providers", "Done")}
            </.action_button>
          </div>
        </:footer>
      </TymeslotWeb.Components.CoreComponents.Modal.modal>
    </div>
    """
  end

  slot :inner_block, required: true

  defp calendar_badge(assigns) do
    ~H"""
    <span class="rounded-token-sm bg-tymeslot-100 px-1.5 py-0.5 text-token-2xs font-black uppercase tracking-tighter text-tymeslot-600">
      {render_slot(@inner_block)}
    </span>
    """
  end

  attr :id, :string, required: true
  attr :calendar, :map, required: true
  attr :kind, :atom, required: true
  attr :integration_id, :integer, required: true
  attr :target, :any, required: true
  attr :booking?, :boolean, default: false, doc: "whether bookings go to this calendar"

  defp calendar_controls(%{kind: :exchange_main} = assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <.segmented_control
        id={"#{@id}-shown"}
        size={:sm}
        value={to_string(@calendar.selected)}
        aria_label={
          dgettext("dashboard_calendar_providers", "Show %{calendar} on your calendar",
            calendar: name(@calendar)
          )
        }
        on_change={push("set_calendar_shown", @integration_id, @calendar.id, @target)}
        param="shown"
      >
        <:option value="false" label={dgettext("dashboard_calendar_providers", "Off")} />
        <:option value="true" label={dgettext("dashboard_calendar_providers", "On")} />
      </.segmented_control>
      <.segmented_control
        id={"#{@id}-busy"}
        size={:sm}
        value={to_string(@calendar.blocks_availability)}
        aria_label={
          dgettext("dashboard_calendar_providers", "Busy times of %{calendar}",
            calendar: name(@calendar)
          )
        }
        on_change={push("set_calendar_blocking", @integration_id, @calendar.id, @target)}
        param="blocks"
      >
        <:option value="true" label={dgettext("dashboard_calendar_providers", "Block")} />
        <:option
          value="false"
          label={dgettext("dashboard_calendar_providers", "Don't block")}
          disabled={@booking?}
        />
      </.segmented_control>
    </div>
    """
  end

  defp calendar_controls(assigns) do
    ~H"""
    <.segmented_control
      id={"#{@id}-state"}
      size={:sm}
      value={Blocking.state(@calendar)}
      aria_label={
        dgettext("dashboard_calendar_providers", "Use of %{calendar}", calendar: name(@calendar))
      }
      on_change={push("set_calendar_state", @integration_id, @calendar.id, @target)}
      param="state"
    >
      <:option
        value="off"
        label={dgettext("dashboard_calendar_providers", "Off")}
        disabled={@kind == :booking}
      />
      <:option
        :if={@kind != :free_busy_only}
        value="show"
        label={dgettext("dashboard_calendar_providers", "Show only")}
        disabled={@kind == :booking}
      />
      <:option
        :if={@kind != :exchange_folder}
        value="block"
        label={
          if @kind == :free_busy_only,
            do: dgettext("dashboard_calendar_providers", "Block"),
            else: dgettext("dashboard_calendar_providers", "Show and block")
        }
      />
    </.segmented_control>
    """
  end

  defp push(event, integration_id, calendar_id, target),
    do:
      JS.push(event,
        value: %{integration_id: integration_id, calendar_id: calendar_id},
        target: target
      )

  defp name(calendar), do: DisplayHelpers.extract_calendar_display_name(calendar)

  # The same id matcher the context refuses by, so the options disabled here
  # are exactly the ones it would refuse.
  defp booking_calendar?(calendar, booking_calendar_ids),
    do: Enum.any?(booking_calendar_ids, &UriUtils.uri_safe_match?(&1, calendar.id))

  defp kind(calendar, exchange?, booking_calendar_ids) do
    cond do
      exchange? and calendar.primary -> :exchange_main
      exchange? -> :exchange_folder
      booking_calendar?(calendar, booking_calendar_ids) -> :booking
      calendar.free_busy_only -> :free_busy_only
      true -> :other
    end
  end

  defp helper(:booking, _whole_mailbox?),
    do:
      dgettext(
        "dashboard_calendar_providers",
        "Your booking calendar always blocks your availability."
      )

  defp helper(:free_busy_only, _whole_mailbox?),
    do:
      dgettext(
        "dashboard_calendar_providers",
        "Shared with you as busy times only. Tymeslot can block these times but cannot show the events."
      )

  defp helper(:exchange_main, _whole_mailbox?),
    do:
      dgettext(
        "dashboard_calendar_providers",
        "Exchange reports busy times for your whole mailbox from your main calendar, so this choice works whether or not the calendar is shown."
      )

  defp helper(:exchange_folder, true),
    do:
      dgettext(
        "dashboard_calendar_providers",
        "This folder's events are shown only; busy times come from your whole mailbox."
      )

  defp helper(:exchange_folder, false),
    do:
      dgettext(
        "dashboard_calendar_providers",
        "Exchange reports busy times for your main calendar only."
      )

  defp helper(:other, _whole_mailbox?), do: nil
end
