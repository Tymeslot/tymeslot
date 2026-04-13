defmodule Tymeslot.Emails.Shared.MeetingComponents do
  @moduledoc """
  Meeting-specific MJML components for Tymeslot emails — 2026 redesign.

  The big idea: instead of presenting a meeting as a 2×2 emoji grid, we lead
  with a **typographic hero** — the date set in display type, the time
  immediately beneath, and the supporting details (duration, location, type)
  demoted to a compact row beneath a hairline. It reads like a moment, not a
  form.

  Components:

  - `meeting_details_table/1,2` — the hero block (retains its name for
    backward compatibility with every caller).
  - `video_meeting_section/2` — a ticket-stub CTA with a coloured rail on the
    left, a clear join button, and context-aware intent colouring.
  - `time_alert_badge/2` — a prominent pill badge for reminder emails.
  - `meeting_actions_bar/1` — the reschedule / cancel action row, rendered as
    text links to keep a single primary CTA elsewhere in the email.
  - `calendar_links_section/1` — the add-to-calendar links card.
  - `attendee_info_section/1` — the organiser-facing attendee contact block.
  - `attendee_message_box/1` — the callout for a booker's attendee note.
  """

  alias Tymeslot.Emails.Shared.{Formatting, Sanitise, Styles, Urls}
  alias Tymeslot.Emails.Shared.Styles.Tokens
  alias Tymeslot.Security.{UniversalSanitizer, UrlValidation}

  @type attendee_info :: %{
          required(:name) => String.t(),
          required(:email) => String.t(),
          optional(:phone) => String.t() | nil,
          optional(:company) => String.t() | nil,
          optional(:timezone) => String.t() | nil,
          optional(atom()) => term()
        }

  use Gettext, backend: TymeslotWeb.Gettext

  @type meeting_details :: %{
          required(:date) => Date.t() | DateTime.t(),
          required(:start_time) => DateTime.t(),
          required(:duration) => integer(),
          optional(:location) => String.t() | nil,
          optional(:location_type) => atom() | nil,
          optional(:meeting_type) => String.t() | nil,
          optional(:timezone) => String.t() | nil,
          optional(atom()) => term()
        }

  @type button_spec :: %{
          required(:text) => String.t(),
          required(:url) => String.t(),
          optional(:style) => atom(),
          optional(:opts) => keyword()
        }

  @doc "The hero meeting block, in the default locale."
  @spec meeting_details_table(meeting_details()) :: String.t()
  def meeting_details_table(details), do: meeting_details_table(details, "en")

  @doc "The hero meeting block, locale-aware."
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

  @doc """
  A video meeting section — ticket-stub feel with a left colour rail and a
  prominent join button. The colour comes from the supplied intent.

  Options: `:title`, `:button_text`, `:show_time_note`.
  """
  @spec video_meeting_section(Tokens.intent(), String.t(), keyword()) :: String.t()
  def video_meeting_section(intent, meeting_url, opts \\ []) when is_atom(intent) do
    title = Keyword.get(opts, :title, dgettext("emails", "Join Video Meeting"))
    button_text = Keyword.get(opts, :button_text, dgettext("emails", "Join Meeting"))
    show_time_note = Keyword.get(opts, :show_time_note, false)

    safe_title = Sanitise.sanitize_for_email(title)
    safe_button_text = Sanitise.sanitize_for_email(button_text)
    safe_url = sanitize_url(meeting_url)

    tokens = Styles.intent(intent)

    time_note_block =
      if show_time_note do
        """
        <mj-text
          font-size="12px"
          color="#{tokens.accent_ink}"
          align="left"
          padding="8px 0 0 0"
          line-height="1.5"
        >
          #{dgettext("emails", "Meeting will start at the scheduled time")}
        </mj-text>
        """
      else
        ""
      end

    """
    <mj-section
      background-color="#{tokens.tint}"
      border-left="4px solid #{tokens.accent}"
      border-radius="#{Styles.radius(:md)}"
      padding="18px 20px"
      css-class="mobile-card"
    >
      <mj-column>
        <mj-text
          font-size="11px"
          font-weight="700"
          color="#{tokens.accent_ink}"
          letter-spacing="0.12em"
          text-transform="uppercase"
          padding="0 0 4px 0"
          css-class="mobile-eyebrow"
        >
          #{dgettext("emails", "Video call")}
        </mj-text>
        <mj-text
          font-size="16px"
          font-weight="700"
          color="#{tokens.accent_ink}"
          padding="0 0 12px 0"
          line-height="1.35"
        >
          #{safe_title}
        </mj-text>
        <mj-button
          href="#{safe_url}"
          background-color="#{tokens.accent}"
          color="#ffffff"
          font-weight="700"
          font-size="15px"
          align="left"
          width="auto"
          inner-padding="13px 24px"
          border-radius="#{Styles.radius(:pill)}"
          css-class="mobile-button"
        >
          #{safe_button_text}
        </mj-button>
        #{time_note_block}
      </mj-column>
    </mj-section>
    """
  end

  @doc """
  A prominent time alert pill — usually used inside reminder emails. The caller
  supplies the intent explicitly so the pill always matches the email's stage
  band.

  Options: `:icon`.
  """
  @spec time_alert_badge(Tokens.intent(), String.t(), keyword()) :: String.t()
  def time_alert_badge(intent, time_text, opts \\ []) when is_atom(intent) do
    icon = Keyword.get(opts, :icon, "")
    safe_text = Sanitise.sanitize_for_email(time_text)
    safe_icon = Sanitise.sanitize_for_email(icon)

    tokens = Styles.intent(intent)

    label =
      if safe_icon == "", do: safe_text, else: "#{safe_icon} #{safe_text}"

    """
    <mj-section padding="0 0 10px 0">
      <mj-column>
        <mj-text
          align="center"
          padding="0"
          font-size="0"
        >
          <span style="display: inline-block; padding: 10px 22px; border-radius: #{Styles.radius(:pill)}; background: #{tokens.tint}; color: #{tokens.accent_ink}; font-size: 13px; font-weight: 700; letter-spacing: 0.06em; text-transform: uppercase;">#{label}</span>
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  @doc """
  A meeting actions bar — reschedule / cancel links. Rendered as a compact row
  of text links separated by a middle dot, so the primary CTA (join button)
  stays visually dominant.

  The caller supplies the email's `intent`. The link colour per action depends
  on its `:style` key: `:primary` inherits the email intent's deep accent,
  `:danger` uses the cancelled intent (always rose), `:secondary` uses the
  muted ink.
  """
  @spec meeting_actions_bar(Tokens.intent(), list(button_spec())) :: String.t()
  def meeting_actions_bar(intent, actions) when is_atom(intent) and is_list(actions) do
    separator = ~s(<span style="color: #{Styles.ink_whisper()}; padding: 0 12px;">·</span>)

    links =
      Enum.map_join(actions, separator, fn action ->
        safe_text = Sanitise.sanitize_for_email(action.text)
        safe_url = sanitize_url(action.url)
        color = action_link_color(intent, Map.get(action, :style, :primary))

        ~s(<a href="#{safe_url}" style="color: #{color}; text-decoration: none; font-weight: 600; border-bottom: 1px solid #{Styles.hairline()}; padding-bottom: 1px;">#{safe_text}</a>)
      end)

    """
    <mj-section padding="14px 0 4px 0">
      <mj-column>
        <mj-text
          align="center"
          font-size="14px"
          color="#{Styles.ink_muted()}"
          letter-spacing="0.02em"
        >
          #{links}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  @doc "Formats the meeting time line using the default locale."
  @spec format_meeting_time(meeting_details()) :: String.t()
  def format_meeting_time(details), do: format_meeting_time(details, "en")

  @doc "Formats the meeting time line in a specific locale."
  @spec format_meeting_time(meeting_details(), String.t()) :: String.t()
  def format_meeting_time(details, locale) do
    case details do
      %{start_time: %DateTime{} = start_time, timezone: timezone} when is_binary(timezone) ->
        formatted = Formatting.format_time(start_time, locale)

        if timezone != "UTC",
          do: "#{formatted} (#{timezone})",
          else: formatted

      %{start_time: %DateTime{} = start_time} ->
        Formatting.format_time(start_time, locale)

      _other ->
        dgettext("emails", "TBD")
    end
  end

  # ========== Hero block helpers ==========

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
      font-size="34px"
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

  # ========== Style helpers ==========

  # Action link colouring. `:danger` is always rose (cancel is cancel), `:secondary`
  # is always muted ink, and `:primary` inherits the surrounding email intent.
  @spec action_link_color(Tokens.intent(), :primary | :secondary | :danger) :: String.t()
  defp action_link_color(_intent, :danger), do: Styles.intent_accent_deep(:cancelled)
  defp action_link_color(_intent, :secondary), do: Styles.ink_muted()
  defp action_link_color(intent, :primary), do: Styles.intent_accent_deep(intent)

  defp sanitize_url(url) do
    case UrlValidation.validate_http_url(url) do
      :ok -> Sanitise.sanitize_for_email(url)
      _other -> "#"
    end
  end

  # ========== Calendar links ==========

  @doc "An add-to-calendar card with Google, Outlook and Yahoo buttons."
  @spec calendar_links_section(%{
          required(:title) => String.t(),
          required(:start_time) => DateTime.t(),
          required(:end_time) => DateTime.t(),
          required(:description) => String.t(),
          required(:location) => String.t(),
          optional(atom()) => term()
        }) :: String.t()
  def calendar_links_section(meeting_details) do
    links = Urls.calendar_links(meeting_details)

    """
    <mj-section
      background-color="#{Styles.canvas_soft()}"
      border-radius="#{Styles.card_radius()}"
      padding="20px 22px 8px 22px"
      css-class="mobile-card"
    >
      <mj-column>
        <mj-text
          align="left"
          font-size="11px"
          font-weight="700"
          color="#{Styles.ink_muted()}"
          letter-spacing="0.14em"
          text-transform="uppercase"
          padding="0 0 12px 0"
        >
          #{dgettext("emails", "Add to your calendar")}
        </mj-text>
      </mj-column>
    </mj-section>
    <mj-section
      background-color="#{Styles.canvas_soft()}"
      border-radius="0 0 #{Styles.card_radius()} #{Styles.card_radius()}"
      padding="0 14px 20px 14px"
    >
      <mj-group>
        #{calendar_button(links.google, "Google")}
        #{calendar_button(links.outlook, "Outlook")}
        #{calendar_button(links.yahoo, "Yahoo")}
      </mj-group>
    </mj-section>
    """
  end

  @doc """
  Attendee information section — key/value block for organiser emails. The
  caller supplies the email `intent` so the mailto link colour stays
  consistent with the surrounding stage band.
  """
  @spec attendee_info_section(Tokens.intent(), attendee_info()) :: String.t()
  def attendee_info_section(intent, attendee) when is_atom(intent) do
    safe_name = Sanitise.sanitize_for_email(attendee.name)
    safe_email = Sanitise.sanitize_for_email(attendee.email)

    """
    <mj-section padding="8px 0 20px 0">
      <mj-column>
        <mj-text
          font-size="11px"
          font-weight="700"
          color="#{Styles.ink_muted()}"
          letter-spacing="0.14em"
          text-transform="uppercase"
          padding="0 0 12px 0"
        >
          #{dgettext("emails", "Attendee Information")}
        </mj-text>
        <mj-table #{Styles.table_attributes()} css-class="responsive-table">
          #{attendee_row(dgettext("emails", "Name"), safe_name)}
          #{attendee_email_row(intent, safe_email)}
          #{attendee_optional_row(dgettext("emails", "Phone"), attendee[:phone])}
          #{attendee_optional_row(dgettext("emails", "Company"), attendee[:company])}
          #{attendee_optional_row(dgettext("emails", "Timezone"), attendee[:timezone])}
        </mj-table>
      </mj-column>
    </mj-section>
    """
  end

  @doc """
  A small tinted callout for the attendee's message left during booking. The
  caller supplies the email `intent` so the tint matches the stage band.
  """
  @spec attendee_message_box(Tokens.intent(), String.t() | nil) :: String.t()
  def attendee_message_box(intent, message)
      when is_atom(intent) and is_binary(message) and message != "" do
    sanitized =
      case UniversalSanitizer.sanitize_and_validate(message,
             allow_html: false,
             on_too_long: :truncate
           ) do
        {:ok, value} -> value
        {:error, _reason} -> Sanitise.sanitize_for_email(message)
      end

    tokens = Styles.intent(intent)

    """
    <mj-section
      padding="14px 18px"
      background-color="#{tokens.tint}"
      border-left="4px solid #{tokens.accent}"
      border-radius="#{Styles.radius(:md)}"
      css-class="mobile-card"
    >
      <mj-column>
        <mj-text
          font-size="11px"
          font-weight="700"
          color="#{tokens.accent_ink}"
          letter-spacing="0.12em"
          text-transform="uppercase"
          padding="0 0 4px 0"
        >
          #{dgettext("emails", "Message from attendee")}
        </mj-text>
        <mj-text
          font-size="14px"
          color="#{tokens.accent_ink}"
          line-height="1.6"
          padding="0"
          font-style="italic"
        >
          "#{sanitized}"
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  def attendee_message_box(intent, _message) when is_atom(intent), do: ""

  defp calendar_button(url, label) do
    """
    <mj-column>
      <mj-button
        href="#{url}"
        background-color="#{Styles.surface()}"
        color="#{Styles.ink_soft()}"
        border="1px solid #{Styles.hairline()}"
        border-radius="#{Styles.radius(:pill)}"
        font-size="13px"
        font-weight="600"
        inner-padding="10px 16px"
      >
        #{label}
      </mj-button>
    </mj-column>
    """
  end

  defp attendee_row(label, value) do
    """
    <tr style="#{Styles.table_row_style()}">
      <td style="#{Styles.table_label_style()}">#{label}</td>
      <td style="#{Styles.table_value_style()}">#{value}</td>
    </tr>
    """
  end

  defp attendee_email_row(intent, safe_email) do
    """
    <tr style="#{Styles.table_row_style()}">
      <td style="#{Styles.table_label_style()}">#{dgettext("emails", "Email")}</td>
      <td style="#{Styles.table_value_style()}">
        <a href="mailto:#{safe_email}" style="color: #{Styles.intent_accent_deep(intent)}; font-weight: 600; text-decoration: none;">#{safe_email}</a>
      </td>
    </tr>
    """
  end

  defp attendee_optional_row(_label, nil), do: ""
  defp attendee_optional_row(_label, ""), do: ""

  defp attendee_optional_row(label, value) do
    safe_value = Sanitise.sanitize_for_email(value)
    attendee_row(label, safe_value)
  end
end
