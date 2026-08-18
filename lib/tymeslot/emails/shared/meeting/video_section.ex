defmodule Tymeslot.Emails.Shared.Meeting.VideoSection do
  @moduledoc """
  Video-meeting blocks for emails — the ticket-stub join CTA and the matching
  reminder-time pill.

  Both components take an explicit intent so they always match the surrounding
  email's stage band.
  """

  alias Tymeslot.Emails.Shared.{Sanitise, Styles}
  alias Tymeslot.Emails.Shared.Styles.Tokens

  use Gettext, backend: TymeslotWeb.Gettext

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
    safe_url = Sanitise.sanitize_url(meeting_url)

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
          background-color="#{tokens.accent_deep}"
          color="#{Styles.button_text_color(tokens.accent_deep)}"
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
end
