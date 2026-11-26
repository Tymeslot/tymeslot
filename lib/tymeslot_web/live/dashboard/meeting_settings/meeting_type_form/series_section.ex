defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.SeriesSection do
  @moduledoc """
  The meeting-type form's Series section: whether a booker may book several
  sessions of this type in one go, and how (`Tymeslot.MeetingTypes.SeriesSettings`).

  One switch turns the series on. Two cards then choose its mode: the same
  time on a rhythm the host sets (`:recurring`, with a frequency and an
  interval), or sessions the booker picks at any offered times (`:flexible`).
  Below them sit the number of sessions (a range, or a fixed number), and
  whether a booker may also book a single session. A mode the type cannot
  offer (`SeriesSettings.conflicts/1`: one-off, invitation-only, recurring on
  fixed dates, email confirmation, or a paid group type) renders disabled with the
  reason, and the switch does too when neither mode is possible.

  The form state is the `:series` assign, and every control dispatches
  `update_series` to the parent `MeetingTypeForm`, which hands it to
  `SeriesHandlers`: clicks carry `series_action`, and the inputs post
  `series[...]`, a name of their own so the form's other change handlers
  never read them. `Submission.build_params/1` posts the state.

  Series are a Pro feature on the managed plan (`recurring_bookings_allowed`).
  Without it a type with no series shows the upgrade placeholder registered
  under `:feature_placeholder_components[:recurring_bookings]`; a type that
  already has one keeps its settings, read-only and without the notes, and
  books single sessions until the host upgrades. The switch stays usable
  there, to turn the series off; every other event is ignored, and
  `Tymeslot.MeetingTypes.FormValidation` refuses a forged one on save.

  The notes here are informational and never block a save: the booking
  window bounds only the first session, a booking limit can be too low for a
  whole series (`SeriesHandlers.limit_notes/2`, also shown by the limits section), and a
  group or paid series counts per session.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MeetingPayments.Money
  alias Tymeslot.MeetingTypes.SeriesSettings
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.SeriesHandlers
  alias TymeslotWeb.Helpers.ContextErrors
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  attr :series, :map, required: true
  attr :allowed, :boolean, required: true
  attr :type, :any, required: true
  attr :fixed_dates, :boolean, default: false
  attr :requires_email_verification, :boolean, default: false
  attr :booking_window_days, :integer, required: true
  attr :booking_limits, :map, required: true
  attr :group, :boolean, default: false
  attr :allow_guests, :boolean, default: false
  attr :payment_required, :boolean, default: false
  attr :payment_price, :string, default: ""
  attr :payment_currency, :string, default: "usd"
  attr :form_id, :string, required: true
  attr :current_user, :any, default: nil
  attr :form_errors, :map, default: %{}
  attr :myself, :any, required: true

  @spec series_section(map()) :: Phoenix.LiveView.Rendered.t()
  def series_section(%{allowed: false, series: %{series_mode: nil}} = assigns) do
    assigns = assign(assigns, :placeholder_component, placeholder_component())

    ~H"""
    <section data-testid="series-locked">
      <%= if @placeholder_component do %>
        <.live_component
          module={@placeholder_component}
          id={"recurring-bookings-upgrade-#{@form_id}"}
          feature={:recurring_bookings}
          current_user={@current_user}
        />
      <% else %>
        <%!-- No placeholder registered: a minimal notice rather than nothing,
              so a misconfiguration is noticed. --%>
        <.card class="text-center">
          <p class="text-token-sm text-tymeslot-500">
            {ContextErrors.recurring_bookings_not_allowed_message()}
          </p>
        </.card>
      <% end %>
    </section>
    """
  end

  def series_section(assigns) do
    series = assigns.series
    conflicts = SeriesHandlers.mode_conflicts(assigns)

    assigns =
      assign(assigns,
        read_only: not assigns.allowed,
        on: series.series_mode != nil,
        recurring_conflict: conflicts.recurring,
        flexible_conflict: conflicts.flexible,
        limit_notes: SeriesHandlers.limit_notes(series, assigns.booking_limits),
        price: price(assigns.payment_price, assigns.payment_currency),
        rhythm_errors: errors(assigns.form_errors, [:series_frequency, :series_interval]),
        min_errors:
          errors(
            assigns.form_errors,
            if(series.fixed,
              do: [:series_min_occurrences, :series_max_occurrences],
              else: [:series_min_occurrences]
            )
          ),
        max_errors: errors(assigns.form_errors, [:series_max_occurrences]),
        other_errors: errors(assigns.form_errors, [:series_mode, :series_required])
      )

    assigns =
      assign(
        assigns,
        :toggle_blocked,
        not assigns.on and assigns.recurring_conflict != nil and assigns.flexible_conflict != nil
      )

    ~H"""
    <section class="space-y-4" data-testid="series-section">
      <.subsection_header
        icon="hero-arrow-path"
        title={dgettext("dashboard_booking_series", "Series")}
      />

      <.note :if={@read_only} variant={:warning} testid="series-paused">
        {dgettext(
          "dashboard_booking_series",
          "Series booking is paused: this meeting type books single sessions until you upgrade."
        )}
      </.note>

      <.setting_row
        id={"series-toggle-#{@form_id}"}
        label={dgettext("dashboard_booking_series", "Let people book a series")}
        description={
          dgettext(
            "dashboard_booking_series",
            "Bookers book several sessions in one go, with one confirmation."
          )
        }
        checked={@on}
        disabled={(@read_only and not @on) or @toggle_blocked}
        on_change="update_series"
        target={@myself}
        phx-value-series_action="toggle"
      >
        <:disabled_reason :if={@toggle_blocked}>{@recurring_conflict}</:disabled_reason>
      </.setting_row>

      <div :if={@on} class="space-y-4">
        <div
          role="group"
          aria-label={dgettext("dashboard_booking_series", "How the sessions are timed")}
          class="grid grid-cols-1 gap-3 sm:grid-cols-2"
        >
          <.mode_card
            mode="recurring"
            selected={@series.series_mode == :recurring}
            conflict={@recurring_conflict}
            read_only={@read_only}
            form_id={@form_id}
            myself={@myself}
            icon="hero-arrow-path"
            title={dgettext("dashboard_booking_series", "Same time, repeating")}
            description={
              dgettext(
                "dashboard_booking_series",
                "Every session at the same time, for example every Thursday at 17:00."
              )
            }
          />
          <.mode_card
            mode="flexible"
            selected={@series.series_mode == :flexible}
            conflict={@flexible_conflict}
            read_only={@read_only}
            form_id={@form_id}
            myself={@myself}
            icon="hero-squares-2x2"
            title={dgettext("dashboard_booking_series", "Sessions at different times")}
            description={
              dgettext(
                "dashboard_booking_series",
                "Bookers pick each session from your available times."
              )
            }
          />
        </div>

        <div :if={@series.series_mode == :recurring} class="space-y-2" data-testid="series-rhythm">
          <div class="max-w-xs">
            <.select
              id={"series-rhythm-#{@form_id}"}
              name="series[rhythm]"
              label={dgettext("dashboard_booking_series", "Repeats")}
              value={"#{@series.series_frequency}:#{@series.series_interval}"}
              options={rhythm_options()}
              errors={@rhythm_errors}
              disabled={@read_only}
              phx-change="update_series"
              phx-target={@myself}
            />
          </div>
          <p :if={@series.series_frequency == :monthly} class="text-token-sm text-tymeslot-600">
            {dgettext(
              "dashboard_booking_series",
              "On the same weekday of the month, for example the second Thursday."
            )}
          </p>
        </div>

        <div class="space-y-3">
          <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <.input
              type="number"
              id={"series-min-#{@form_id}"}
              name="series[min]"
              label={
                if @series.fixed,
                  do: dgettext("dashboard_booking_series", "Number of sessions"),
                  else: dgettext("dashboard_booking_series", "From")
              }
              value={@series.series_min_occurrences}
              errors={@min_errors}
              min={first_count()}
              max={last_count()}
              step="1"
              disabled={@read_only}
              phx-change="update_series"
              phx-debounce="500"
              phx-target={@myself}
            />
            <.input
              :if={not @series.fixed}
              type="number"
              id={"series-max-#{@form_id}"}
              name="series[max]"
              label={dgettext("dashboard_booking_series", "To")}
              value={@series.series_max_occurrences}
              errors={@max_errors}
              min={first_count()}
              max={last_count()}
              step="1"
              disabled={@read_only}
              phx-change="update_series"
              phx-debounce="500"
              phx-target={@myself}
            />
          </div>
          <p class="text-token-sm text-tymeslot-600" data-testid="series-count-summary">
            {count_summary(@series)}
          </p>
          <.setting_row
            id={"series-fixed-#{@form_id}"}
            label={dgettext("dashboard_booking_series", "Fixed number")}
            description={
              dgettext(
                "dashboard_booking_series",
                "Every series has the same number of sessions, like a course."
              )
            }
            checked={@series.fixed}
            disabled={@read_only}
            on_change="update_series"
            target={@myself}
            phx-value-series_action="fixed"
          />
        </div>

        <.setting_row
          id={"series-single-#{@form_id}"}
          label={dgettext("dashboard_booking_series", "Bookers can also book a single session")}
          checked={not @series.series_required}
          disabled={@read_only}
          on_change="update_series"
          target={@myself}
          phx-value-series_action="single"
        />

        <%!-- How the series meets the type's other settings; nothing here
              applies while the series is paused. --%>
        <div :if={not @read_only} class="space-y-3">
          <.note variant={:info} testid="series-booking-window">
            {dgettext(
              "dashboard_booking_series",
              "Your booking window (%{days} days) applies to the first session only. Later sessions can be booked up to 12 months ahead.",
              days: @booking_window_days
            )}
          </.note>
          <.note :for={note <- @limit_notes} variant={:warning} testid="series-limit-conflict">
            {note}
          </.note>
          <.note :if={@group} variant={:info} testid="series-group">
            {dgettext("dashboard_booking_series", "Each session in a series takes one seat.")}
          </.note>
          <.note :if={@allow_guests} variant={:info} testid="series-guests">
            {dgettext(
              "dashboard_booking_series",
              "Guests can only be added to single bookings, not to a series."
            )}
          </.note>
          <.note :if={@payment_required} variant={:info} testid="series-paid">
            {dgettext(
              "dashboard_booking_series",
              "Bookers pay %{price} × the number of sessions upfront.",
              price: @price
            )}
          </.note>
        </div>
      </div>

      <p :for={error <- @other_errors} class="form-error">{error}</p>
    </section>
    """
  end

  attr :mode, :string, required: true
  attr :selected, :boolean, required: true
  attr :conflict, :string, default: nil
  attr :read_only, :boolean, required: true
  attr :form_id, :string, required: true
  attr :myself, :any, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true

  defp mode_card(assigns) do
    assigns = assign(assigns, :disabled, assigns.read_only or assigns.conflict != nil)

    ~H"""
    <div class="space-y-1">
      <button
        type="button"
        id={"series-mode-#{@mode}-#{@form_id}"}
        data-testid={"series-mode-#{@mode}"}
        phx-click="update_series"
        phx-value-series_action="mode"
        phx-value-mode={@mode}
        phx-target={@myself}
        disabled={@disabled}
        aria-pressed={to_string(@selected)}
        aria-describedby={@conflict && "series-mode-#{@mode}-#{@form_id}-reason"}
        class={[
          "flex h-full w-full items-start gap-3 rounded-token-xl border-2 p-4 text-left transition-all",
          "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-turquoise-400",
          @selected && "border-turquoise-500 bg-turquoise-50",
          not @selected && "border-tymeslot-100 bg-white",
          (not @selected and not @disabled) && "hover:border-turquoise-300",
          @disabled && "cursor-not-allowed opacity-60"
        ]}
      >
        <.icon name={@icon} class="mt-0.5 h-5 w-5 shrink-0 text-turquoise-600" />
        <span class="block min-w-0 space-y-1">
          <span class="block text-token-sm font-semibold text-tymeslot-800">{@title}</span>
          <span class="block text-token-sm text-tymeslot-600">{@description}</span>
        </span>
      </button>
      <p
        :if={@conflict}
        id={"series-mode-#{@mode}-#{@form_id}-reason"}
        class="text-token-sm font-medium text-tymeslot-700"
        data-testid={"series-mode-#{@mode}-reason"}
      >
        {@conflict}
      </p>
    </div>
    """
  end

  attr :testid, :string, required: true
  attr :variant, :atom, required: true, values: [:info, :warning]
  slot :inner_block, required: true

  @doc """
  One of the section's notes: an `info_box` at the size of a form hint. The
  limits section shows its booking-limit conflicts with it too.
  """
  @spec note(map()) :: Phoenix.LiveView.Rendered.t()
  def note(assigns) do
    ~H"""
    <div data-testid={@testid}>
      <.info_box variant={@variant} class="mb-0! p-4! text-token-sm">
        {render_slot(@inner_block)}
      </.info_box>
    </div>
    """
  end

  defp errors(form_errors, fields) do
    fields
    |> Enum.flat_map(&FormValidationHelpers.field_errors(form_errors, &1))
    |> Enum.map(&Helpers.format_errors/1)
  end

  # Every rhythm a recurring series can take, as one choice:
  # `"<frequency>:<interval>"`.
  defp rhythm_options do
    for frequency <- [:daily, :weekly, :monthly], interval <- SeriesSettings.intervals() do
      {rhythm_label(frequency, interval), "#{frequency}:#{interval}"}
    end
  end

  defp rhythm_label(:daily, n),
    do: dngettext("dashboard_booking_series", "Every day", "Every %{count} days", n)

  defp rhythm_label(:weekly, n),
    do: dngettext("dashboard_booking_series", "Every week", "Every %{count} weeks", n)

  defp rhythm_label(:monthly, n),
    do: dngettext("dashboard_booking_series", "Every month", "Every %{count} months", n)

  defp count_summary(%{fixed: true, series_min_occurrences: count}),
    do:
      dngettext(
        "dashboard_booking_series",
        "Every series has %{count} session.",
        "Every series has %{count} sessions.",
        count
      )

  defp count_summary(%{series_min_occurrences: min, series_max_occurrences: max}),
    do:
      dgettext(
        "dashboard_booking_series",
        "From %{min} to %{max} sessions, as the booker chooses.",
        min: min,
        max: max
      )

  defp first_count, do: SeriesSettings.count_bounds().first
  defp last_count, do: SeriesSettings.count_bounds().last

  # The price per session as the booker pays it, or the typed text when it
  # does not parse yet.
  defp price(price, currency) when is_binary(price) do
    case Money.parse(price, currency) do
      {:ok, cents} -> Money.format(cents, currency)
      _invalid -> price
    end
  end

  defp price(_price, _currency), do: ""

  # Bracket access works for both a keyword list and a map. Core leaves the
  # config unset; the managed overlay registers one.
  defp placeholder_component do
    case Application.get_env(:tymeslot, :feature_placeholder_components) do
      nil -> nil
      placeholders -> placeholders[:recurring_bookings]
    end
  end
end
