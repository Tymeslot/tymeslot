defmodule TymeslotWeb.Themes.Shared.Components.SeriesPage do
  @moduledoc """
  The body of the attendee's series page (`/:username/series/:series_uid`),
  the same in every theme: Quill and Rhythm draw it inside their own card
  (`Meeting.Series`), a theme with a page shell gets it from
  `Shared.DefaultPages`.

  It names the series ("Mentoring: 4 sessions with Grace") and its rhythm,
  lists every session in the booker's timezone with how it stands and, for
  each one still to come, its own reschedule and cancel links, then offers
  one action for the whole series behind a confirmation step: "Cancel all
  remaining sessions", or "Withdraw request" while the host has not
  answered. The events are `TymeslotWeb.Themes.Core.SeriesManagement`'s.

  The markup carries the `manage-page__*` classes of the default meeting
  pages (`manage-pages.css`) and the session list of `series.css`, both
  styled through the theme's tokens.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  alias Phoenix.LiveView.JS
  alias Tymeslot.BookingSeries
  alias Tymeslot.ContentTranslations.AttendeeTexts
  alias Tymeslot.Profiles
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.SeriesParts

  @doc """
  The body drawn from the series page's own assigns, as
  `TymeslotWeb.Themes.Core.SeriesManagement.assign_series/2` sets them.
  """
  @spec from_page(map()) :: Phoenix.LiveView.Rendered.t()
  def from_page(assigns) do
    ~H"""
    <.body
      series={@series}
      sessions={@series_sessions}
      upcoming={@series_upcoming}
      held={@series_held}
      open_request={@series_open_request}
      paid={@series_paid}
      timezone={@series_timezone}
      locale={@locale}
      organizer_profile={@organizer_profile}
      confirm={@series_confirm}
      refocus={@series_refocus}
      loading={assigns[:loading] || false}
    />
    """
  end

  attr :series, :map, required: true, doc: "the series, its meeting type preloaded"
  attr :sessions, :list, required: true, doc: "`Tymeslot.BookingSeries.Sessions` sessions"
  attr :upcoming, :integer, required: true, doc: "the sessions cancel-all would cancel"
  attr :held, :integer, required: true, doc: "the sessions held for the host's decision"
  attr :open_request, :boolean, required: true
  attr :paid, :boolean, required: true
  attr :timezone, :string, required: true
  attr :locale, :string, required: true
  attr :organizer_profile, :any, default: nil
  attr :confirm, :atom, default: nil, values: [nil, :cancel_all, :withdraw]

  attr :refocus, :boolean,
    default: false,
    doc: "the confirmation was just closed: its opening button takes the focus back"

  attr :loading, :boolean, default: false

  @doc "The series page's body (see the module docs)."
  @spec body(map()) :: Phoenix.LiveView.Rendered.t()
  def body(assigns) do
    assigns =
      assign(assigns,
        host: host_name(assigns),
        title: title(assigns),
        rule: rule(assigns)
      )

    ~H"""
    <div class="manage-page__header">
      <.icon name="hero-arrow-path" class="manage-page__icon manage-page__icon--primary" />
      <h1 class="manage-page__title" data-testid="series-page-title">{@title}</h1>
      <p :if={@rule} class="manage-page__lead" data-testid="series-rule">{@rule}</p>
    </div>

    <section class="manage-page__details">
      <p class="series-confirmation__label manage-page__muted">
        {dgettext("booking_series", "Times in %{zone}",
          zone: LocalizationHelpers.format_zone_label(nil, nil, @timezone)
        )}
      </p>
      <ol class="series-list series-list--booked" data-testid="series-sessions">
        <li
          :for={session <- @sessions}
          id={"series-session-#{session.position}"}
          class={["series-list__item", "series-list__item--#{session.status}"]}
          data-testid="series-session"
          data-status={session.status}
        >
          <span class="series-list__position" aria-hidden="true">{session.position}</span>
          <span class="series-list__body">
            <span class="series-list__when">
              {LocalizationHelpers.format_meeting_datetime_compact(session.start_time, @timezone)}
            </span>
            <span class={["series-status", "series-status--#{session.status}"]}>
              {status_label(session.status)}
            </span>
            <span :if={session.links} class="series-list__links">
              <a
                :if={session.links.reschedule_url}
                href={session.links.reschedule_url}
                class="series-list__link"
                data-testid="series-session-reschedule"
              >
                {dgettext("booking_series", "Reschedule")}<.link_context
                  session={session}
                  timezone={@timezone}
                />
              </a>
              <a
                :if={session.links.cancel_url}
                href={session.links.cancel_url}
                class="series-list__link"
                data-testid="series-session-cancel"
              >
                {dgettext("booking_series", "Cancel")}<.link_context
                  session={session}
                  timezone={@timezone}
                />
              </a>
            </span>
          </span>
        </li>
      </ol>
    </section>

    {series_action(assigns)}
    """
  end

  # The one action for the whole series, or its confirmation.
  defp series_action(%{confirm: :cancel_all} = assigns) do
    ~H"""
    <div class="manage-page__notice manage-page__notice--danger" role="alert">
      <p class="series-page__confirm" data-testid="series-confirm">
        {dngettext(
          "booking_series",
          "Cancel %{count} upcoming session? This can't be undone.",
          "Cancel %{count} upcoming sessions? This can't be undone.",
          @upcoming
        )}
      </p>
      <p :if={@paid} class="series-page__refund" data-testid="series-refund-warning">
        {dgettext(
          "booking_series",
          "Cancelling doesn't refund your payment automatically. Contact %{host} about a refund.",
          host: @host
        )}
      </p>
    </div>
    <div class="manage-page__actions">
      <button
        type="button"
        class="manage-page__button manage-page__button--danger"
        phx-click="manage_series_cancel_all"
        phx-disable-with={dgettext("booking_series", "Cancelling…")}
        data-testid="series-cancel-all-confirm"
        disabled={@loading}
      >
        {dngettext("booking_series", "Yes, cancel it", "Yes, cancel them", @upcoming)}
      </button>
      <button
        type="button"
        class="manage-page__button manage-page__button--secondary"
        phx-click="manage_series_back"
        phx-mounted={JS.focus()}
        data-testid="series-keep"
      >
        {dgettext("booking_series", "Keep my sessions")}
      </button>
    </div>
    """
  end

  defp series_action(%{confirm: :withdraw} = assigns) do
    ~H"""
    <p
      class="manage-page__notice manage-page__notice--danger"
      role="alert"
      data-testid="series-confirm"
    >
      {dngettext(
        "booking_series",
        "Withdraw your request for %{count} session? This can't be undone.",
        "Withdraw your request for %{count} sessions? This can't be undone.",
        @held
      )}
    </p>
    <div class="manage-page__actions">
      <button
        type="button"
        class="manage-page__button manage-page__button--danger"
        phx-click="manage_series_withdraw"
        phx-disable-with={dgettext("booking_series", "Withdrawing…")}
        data-testid="series-withdraw-confirm"
        disabled={@loading}
      >
        {dgettext("booking_series", "Yes, withdraw it")}
      </button>
      <button
        type="button"
        class="manage-page__button manage-page__button--secondary"
        phx-click="manage_series_back"
        phx-mounted={JS.focus()}
        data-testid="series-keep"
      >
        {dgettext("booking_series", "Keep my request")}
      </button>
    </div>
    """
  end

  defp series_action(%{open_request: true} = assigns) do
    ~H"""
    <p class="manage-page__muted">
      {dgettext("booking_series", "%{host} hasn't answered your request yet.", host: @host)}
    </p>
    <div class="manage-page__actions">
      <button
        type="button"
        class="manage-page__button manage-page__button--danger"
        phx-click="manage_series_confirm"
        phx-value-action="withdraw"
        phx-mounted={SeriesParts.refocus(@refocus)}
        data-testid="series-withdraw"
      >
        {dgettext("booking_series", "Withdraw request")}
      </button>
    </div>
    """
  end

  defp series_action(%{upcoming: upcoming} = assigns) when upcoming > 0 do
    ~H"""
    <div class="manage-page__actions">
      <button
        type="button"
        class="manage-page__button manage-page__button--danger"
        phx-click="manage_series_confirm"
        phx-value-action="cancel_all"
        phx-mounted={SeriesParts.refocus(@refocus)}
        data-testid="series-cancel-all"
      >
        {dgettext("booking_series", "Cancel all remaining sessions")}
      </button>
    </div>
    """
  end

  defp series_action(assigns) do
    ~H"""
    <p class="manage-page__muted" data-testid="series-nothing-left">
      {dgettext("booking_series", "No session of this series is left to come.")}
    </p>
    """
  end

  @doc "How a session stands, in a word or two."
  @spec status_label(BookingSeries.Sessions.status()) :: String.t()
  def status_label(:upcoming), do: dgettext("booking_series", "Upcoming")
  def status_label(:past), do: dgettext("booking_series", "Past")
  def status_label(:cancelled), do: dgettext("booking_series", "Cancelled")
  def status_label(:awaiting_approval), do: dgettext("booking_series", "Awaiting approval")
  def status_label(:awaiting_payment), do: dgettext("booking_series", "Awaiting payment")

  # "Mentoring: 4 sessions with Grace Hopper"
  defp title(%{series: series, sessions: sessions} = assigns) do
    dngettext(
      "booking_series",
      "%{type}: %{count} session with %{host}",
      "%{type}: %{count} sessions with %{host}",
      length(sessions),
      type: type_name(series, sessions, assigns.locale),
      host: host_name(assigns)
    )
  end

  # The booker's copy of the type's name where the booking keeps one in the
  # page's language (`AttendeeTexts`), as a meeting's own pages show it.
  defp type_name(series, [%{meeting: %{} = meeting} | _rest] = sessions, locale) do
    case AttendeeTexts.text(meeting, :meeting_type, locale) do
      name when is_binary(name) and name != meeting.meeting_type -> name
      _original -> type_name(series, sessions)
    end
  end

  defp type_name(series, sessions, _locale), do: type_name(series, sessions)

  defp type_name(%{meeting_type: %{name: name}}, _sessions) when is_binary(name), do: name

  defp type_name(_series, [%{meeting: %{meeting_type: name}} | _rest]) when is_binary(name),
    do: name

  defp type_name(_series, _sessions), do: dgettext("booking_series", "Your sessions")

  defp host_name(%{organizer_profile: profile, sessions: sessions}) do
    Profiles.display_name(profile) || first_organizer_name(sessions)
  end

  defp first_organizer_name([%{meeting: %{organizer_name: name}} | _rest]) when is_binary(name),
    do: name

  defp first_organizer_name(_sessions), do: dgettext("booking_series", "your host")

  attr :session, :map, required: true
  attr :timezone, :string, required: true

  # ", session 2, Tuesday 1 December, 09:00 AM": what a session's link acts
  # on, for a screen reader, which reads the link out of its row.
  defp link_context(assigns) do
    ~H"""
    <span class="sr-only">
      , {dgettext("booking_series", "session %{position}, %{when}",
        position: @session.position,
        when: LocalizationHelpers.format_meeting_datetime_compact(@session.start_time, @timezone)
      )}
    </span>
    """
  end

  # The rhythm of a recurring series, read in the booker's zone; nil for a
  # flexible one. Its day and time are named only while every session
  # still keeps them: a session moved on its own (the first one included)
  # would otherwise put its own day and time on the whole series, so then
  # the rhythm is named alone.
  defp rule(%{series: series, sessions: [_first | _rest] = sessions} = assigns) do
    BookingSeries.describe_rule_for_sessions(
      series,
      Enum.map(sessions, & &1.start_time),
      assigns.locale,
      assigns.timezone
    )
  end

  defp rule(_assigns), do: nil
end
