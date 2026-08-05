defmodule Tymeslot.Emails.Shared.Meeting.Hero do
  @moduledoc """
  The typographic hero block for meeting emails — 2026 redesign.

  Leads with the date set in display type, the time immediately beneath, and a
  compact metadata grid (type, duration, location) under a hairline. Replaces
  the older 2×2 emoji grid so a meeting reads like a moment, not a form.
  """

  alias Tymeslot.Emails.Shared.{Formatting, Sanitise, Styles}

  use Gettext, backend: TymeslotWeb.Gettext

  @type meeting_details :: %{
          required(:date) => Date.t() | DateTime.t(),
          required(:start_time) => DateTime.t(),
          required(:duration) => integer(),
          optional(:location) => String.t() | nil,
          optional(:location_type) => atom() | nil,
          optional(:meeting_type) => String.t() | nil,
          optional(:timezone) => String.t() | nil,
          optional(:time_format) => String.t() | nil,
          optional(atom()) => term()
        }

  @doc "The hero meeting block, rendered in the recipient's locale."
  @spec meeting_details_table(meeting_details(), String.t()) :: String.t()
  def meeting_details_table(details, locale) do
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      weekday = Formatting.format_weekday(details.date, locale)
      date_line = Formatting.format_date(details.date, locale)
      time_line = format_meeting_time(details, locale)
      duration = Formatting.format_duration(details.duration, locale)
      location = Formatting.format_location(details)
      meeting_type = Map.get(details, :meeting_type)

      """
      <mj-section
        background-color="#{Styles.canvas_soft()}"
        border-radius="#{Styles.card_radius()}"
        padding="26px 26px 22px 26px"
        css-class="mobile-card email-canvas-soft hero-card"
      >
        <mj-column>
          #{hero_eyebrow(weekday)}
          #{hero_date(date_line)}
          #{hero_time(time_line)}
          #{hero_divider()}
          #{hero_meta_grid(meeting_type, duration, location)}
        </mj-column>
      </mj-section>
      """
    end)
  end

  @doc "Formats the meeting time line using the default locale."
  @spec format_meeting_time(meeting_details()) :: String.t()
  def format_meeting_time(details), do: format_meeting_time(details, "en")

  @doc "Formats the meeting time line in a specific locale."
  @spec format_meeting_time(meeting_details(), String.t()) :: String.t()
  def format_meeting_time(details, locale) do
    # Set only by organiser-addressed emails; nil everywhere else means the
    # recipient's locale decides.
    time_format = Map.get(details, :time_format)

    case details do
      %{start_time: %DateTime{} = start_time, timezone: timezone} when is_binary(timezone) ->
        formatted = Formatting.format_time(start_time, locale, time_format)

        if timezone != "UTC",
          do: "#{formatted} (#{timezone})",
          else: formatted

      %{start_time: %DateTime{} = start_time} ->
        Formatting.format_time(start_time, locale, time_format)

      _other ->
        dgettext("emails", "TBD")
    end
  end

  defp hero_eyebrow(weekday) do
    safe_weekday = Sanitise.sanitize_for_email(weekday)

    """
    <mj-text
      font-size="11px"
      font-weight="700"
      color="#{Styles.ink_muted()}"
      letter-spacing="0.16em"
      text-transform="uppercase"
      padding="0 0 10px 0"
      align="left"
      css-class="mobile-eyebrow email-ink-muted"
    >
      #{safe_weekday}
    </mj-text>
    """
  end

  defp hero_date(date_line) do
    safe = Sanitise.sanitize_for_email(date_line)

    """
    <mj-text
      font-size="#{Styles.font_size(:hero)}"
      font-weight="800"
      color="#{Styles.ink()}"
      letter-spacing="-0.028em"
      line-height="1.05"
      padding="0"
      align="left"
      css-class="mobile-display email-ink"
    >
      #{safe}
    </mj-text>
    """
  end

  defp hero_time(time_line) do
    safe_time = Sanitise.sanitize_for_email(time_line)

    """
    <mj-text
      font-size="15px"
      color="#{Styles.ink_muted()}"
      padding="8px 0 0 0"
      line-height="1.5"
      align="left"
      css-class="mobile-text email-ink-muted"
    >
      #{safe_time}
    </mj-text>
    """
  end

  defp hero_divider do
    """
    <mj-divider
      border-color="#{Styles.hairline()}"
      border-width="1px"
      padding="18px 0 14px 0"
    />
    """
  end

  defp hero_meta_grid(meeting_type, duration, location) do
    type_row =
      case meeting_type do
        nil -> ""
        type -> hero_meta_row(dgettext("emails", "Meeting type"), type, border_bottom: true)
      end

    """
    #{type_row}
    <mj-table padding="0">
      <tr>
        <td style="vertical-align: top; padding: 12px 12px 0 0; width: 50%;">
          #{hero_meta_label(dgettext("emails", "Duration"))}
          #{hero_meta_value(duration)}
        </td>
        <td style="vertical-align: top; padding: 12px 0 0 12px; width: 50%;">
          #{hero_meta_label(dgettext("emails", "Location"))}
          #{hero_meta_value(location)}
        </td>
      </tr>
    </mj-table>
    """
  end

  defp hero_meta_row(label, value, opts) do
    safe_value = Sanitise.sanitize_for_email(value)

    border =
      if Keyword.get(opts, :border_bottom, false),
        do: "border-bottom: 1px solid #{Styles.hairline()};",
        else: ""

    """
    <mj-table padding="0" css-class="email-hairline-table">
      <tr class="email-hairline-row">
        <td class="email-hairline-row" style="padding: 0 0 12px 0; #{border}">
          #{hero_meta_label(label)}
          <div class="email-ink" style="font-size: 15px; font-weight: 600; color: #{Styles.ink()}; line-height: 1.4;">#{safe_value}</div>
        </td>
      </tr>
    </mj-table>
    """
  end

  defp hero_meta_label(label) do
    safe = Sanitise.sanitize_for_email(label)

    ~s(<div class="email-ink-muted" style="font-size: 11px; font-weight: 700; color: #{Styles.ink_muted()}; letter-spacing: 0.1em; text-transform: uppercase; padding-bottom: 4px;">#{safe}</div>)
  end

  defp hero_meta_value(value) do
    safe = Sanitise.sanitize_for_email(value)

    ~s(<div class="email-ink" style="font-size: 15px; font-weight: 600; color: #{Styles.ink()}; line-height: 1.4;">#{safe}</div>)
  end
end
