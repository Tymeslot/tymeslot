defmodule TymeslotWeb.Themes.Shared.SeriesSummary do
  @moduledoc """
  What every theme's booking form and confirmation say about a series
  (`Journey.Facts.Series`), in the shared copy: the sessions the form is
  about to book and what the submit's description names, and, once booked,
  the confirmation's headline and message and its list of every session
  with a link to manage them all.

  The wording of a single booking stays each theme's own; these lines
  apply only while a series is chosen (`pending_count/1`) or was booked
  (`booked_count/1`), and each theme draws them in its own markup.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  alias Tymeslot.Bookings.MeetingLinks
  alias TymeslotWeb.Themes.Shared.Components.SubmitPrice
  alias TymeslotWeb.Themes.Shared.ConfirmationText
  alias TymeslotWeb.Themes.Shared.Journey.Facts.Series
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.SeriesParts

  @doc "The sessions the booking form books, or nil for a single session."
  @spec pending_count(map()) :: pos_integer() | nil
  def pending_count(assigns), do: Series.count(assigns)

  @doc "The sessions a series booking made, or nil for a single booking."
  @spec booked_count(map()) :: pos_integer() | nil
  def booked_count(%{series: %{}, series_meetings: [_first | _rest] = meetings}),
    do: length(meetings)

  def booked_count(_assigns), do: nil

  @doc "\"4 sessions, first on <the first session>\", for the booking form."
  @spec summary_line(map(), pos_integer()) :: String.t()
  def summary_line(assigns, count) do
    dngettext(
      "booking_series",
      "%{count} session, first on %{date}",
      "%{count} sessions, first on %{date}",
      count,
      date:
        LocalizationHelpers.format_booking_datetime(
          assigns.selected_date,
          assigns.selected_time,
          assigns.user_timezone
        )
    )
  end

  @doc """
  The id the submit's `aria-describedby` names for its amount: a paid
  series' total (`SeriesParts.total/1`), a single booking's price
  (`SubmitPrice.describedby/4`), or nil when there is none.
  """
  @spec price_describedby(map(), pos_integer() | nil) :: String.t() | nil
  def price_describedby(assigns, count) when is_integer(count) do
    if SeriesParts.total_label(
         assigns.meeting_type,
         assigns.host_currency,
         assigns.locale,
         count
       ),
       do: SeriesParts.total_id()
  end

  def price_describedby(assigns, _single),
    do:
      SubmitPrice.describedby(
        assigns.meeting_type,
        assigns.host_currency,
        assigns.locale,
        assigns.is_rescheduling
      )

  @doc """
  The submit's label: "Book 4 sessions" ("Request 4 sessions" on a type the
  host approves first) for a series, else `single`, the theme's own label
  for one booking.
  """
  @spec submit_label(map(), String.t()) :: String.t()
  def submit_label(assigns, single) do
    case pending_count(assigns) do
      count when is_integer(count) -> SeriesParts.submit_label(assigns.meeting_type, count)
      nil -> single
    end
  end

  @doc """
  Whether the submit waits: a known series the booker changed is checked
  again, and booked once that check answers (`Series.rechecking?/1`).
  """
  @spec submit_waits?(map()) :: boolean()
  def submit_waits?(assigns), do: Series.rechecking?(assigns)

  attr :meeting_type, :any, required: true
  attr :currency, :string, default: nil
  attr :locale, :string, required: true
  attr :rescheduling, :boolean, default: false
  attr :count, :integer, default: nil, doc: "the sessions of a series, nil for one booking"
  attr :class, :any, default: nil

  @doc """
  The amount above the submit: a paid series' total (`SeriesParts.total/1`)
  or one booking's price (`SubmitPrice.price/1`); nothing for a free type.
  """
  @spec price(map()) :: Phoenix.LiveView.Rendered.t()
  def price(assigns) do
    ~H"""
    <SeriesParts.total
      :if={@count}
      meeting_type={@meeting_type}
      currency={@currency}
      locale={@locale}
      count={@count}
      class={@class}
    />
    <SubmitPrice.price
      :if={is_nil(@count)}
      meeting_type={@meeting_type}
      currency={@currency}
      locale={@locale}
      rescheduling={@rescheduling}
      class={@class}
    />
    """
  end

  @doc """
  The confirmation's headline for a series: "4 sessions booked", or "Your
  request for 4 sessions has been sent" while the host decides.
  """
  @spec headline(map(), pos_integer()) :: String.t()
  def headline(assigns, count) do
    case ConfirmationText.status(assigns) do
      :held ->
        dngettext(
          "booking_series",
          "Your request for %{count} session has been sent",
          "Your request for %{count} sessions has been sent",
          count
        )

      _booked ->
        dngettext("booking_series", "%{count} session booked", "%{count} sessions booked", count)
    end
  end

  @doc """
  The line under a series' headline: the held request's sentence in
  `theme_key`'s voice while the host decides, else that the details were
  emailed.
  """
  @spec message(map(), atom()) :: String.t()
  def message(assigns, theme_key) do
    case ConfirmationText.status(assigns) do
      :held ->
        ConfirmationText.held_message(assigns[:name], assigns[:organizer_profile], theme_key)

      _booked ->
        dgettext("booking_series", "We've emailed you all the details.")
    end
  end

  attr :series, :any, required: true
  attr :meetings, :list, required: true
  attr :timezone, :string, required: true
  attr :organizer_profile, :any, required: true
  attr :duration, :string, default: nil, doc: "the meeting's length, named before the zone"
  attr :label_class, :any, default: nil
  attr :class, :any, default: nil

  @doc """
  The confirmation's sessions: the length and the zone, every booked
  session with its own links (`SeriesParts.booked_list/1`), then the link
  to manage the whole series.
  """
  @spec booked(map()) :: Phoenix.LiveView.Rendered.t()
  def booked(assigns) do
    assigns =
      assign(
        assigns,
        :manage_url,
        MeetingLinks.series_url(assigns.series, assigns.organizer_profile)
      )

    ~H"""
    <div class={["series-confirmation", @class]}>
      <p class={["series-confirmation__label", @label_class]}>
        <span :if={@duration}>{@duration} ·</span>
        {dgettext("booking_series", "Times in %{zone}",
          zone: LocalizationHelpers.format_zone_label(nil, nil, @timezone)
        )}
      </p>
      <SeriesParts.booked_list
        meetings={@meetings}
        timezone={@timezone}
        organizer_profile={@organizer_profile}
      />
      <a :if={@manage_url} href={@manage_url} class="series-manage-link" data-testid="series-manage">
        <.icon name="hero-squares-2x2-mini" class="series-manage-icon" />
        {dgettext("booking_series", "Manage all sessions")}
      </a>
    </div>
    """
  end
end
