defmodule TymeslotWeb.Themes.Paper.Scheduling.Components.SeriesComponent do
  @moduledoc """
  The series part of Paper's schedule screen (`Journey.Facts.Series`):
  once a time is picked for a meeting type that offers a series, it opens
  below the picker, in the place the details part takes, and the details
  follow below it once every session is available. Paper keeps its two
  working screens, so the series is a part of the second, not a screen of
  its own: the schedule moment collects it between the slot and the
  details (`Paper.Scheduling.Live`).

  A heading, the first session (the time picked) with "Change time", then
  the shared series body (`SeriesChooser`): the rhythm and the session
  count of a recurring series, or the picker of further sessions of a
  flexible one, every session with how it stands, the notices and a paid
  series' total. Under it, until the details can open, the line saying
  why. Another time picked remakes the series from it (`Series.refresh/1`).

  It renders with the schedule component's assigns (`{assigns}`), plus
  `target`. Its heading takes the focus as the details' heading does on a
  pick (`focus_details`, keyed by the pick count, see `Paper.Scheduling.Details`),
  and the details' own heading then does not.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Themes.Paper.Scheduling.Details
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.SeriesChooser

  @doc "The series part: the heading, the first session, the series and why the details wait."
  @spec series(map()) :: Phoenix.LiveView.Rendered.t()
  def series(assigns) do
    assigns =
      assign(assigns,
        can_change_time: Details.time_on_screen?(assigns)
      )

    ~H"""
    <section
      class="paper-book paper-series"
      data-testid="series-step"
      aria-labelledby="paper-series-heading"
    >
      <%!-- Keyed by the pick count, as the details' head is, so every pick
           runs phx-mounted again: it hides the picker on a wide card, focuses
           the heading and brings it into view. --%>
      <div
        id={"paper-series-head-#{assigns[:pick_seq] || 0}"}
        class="paper-book__head"
        phx-mounted={
          @series_focus &&
            JS.add_class("paper-card--booking", to: "#schedule-step")
            |> JS.focus(to: "#paper-series-heading")
            |> JS.dispatch("tymeslot:reveal",
              to: "#paper-series-heading",
              detail: %{until: "#schedule-step .series-list"}
            )
        }
      >
        <h2 id="paper-series-heading" class="paper-heading paper-book__title" tabindex="-1">
          {SeriesChooser.heading(@meeting_type)}
        </h2>
      </div>
      <Details.chosen_time can_change={@can_change_time} testid="paper-series-first">
        {LocalizationHelpers.format_booking_datetime(@selected_date, @selected_time, @user_timezone)}
      </Details.chosen_time>

      <SeriesChooser.chooser {assigns} target={@target} change_time={Details.change_time()} />

      <SeriesChooser.next_hint {assigns} />
    </section>
    """
  end
end
