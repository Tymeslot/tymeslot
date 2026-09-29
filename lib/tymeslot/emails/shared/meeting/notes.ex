defmodule Tymeslot.Emails.Shared.Meeting.Notes do
  @moduledoc """
  The tinted callout that quotes a note someone wrote about the meeting, and
  the organiser-note box built on it for guest-facing emails.

  The heading is what tells the reader whose words they are, so every note
  goes through `callout/3` with a heading naming its author. The attendee's
  message uses the same callout from `Meeting.Attendee`.
  """

  alias Tymeslot.Emails.Shared.{Sanitise, Stack, Styles}
  alias Tymeslot.Emails.Shared.Styles.Tokens
  alias Tymeslot.Security.UniversalSanitizer

  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  The note the organiser wrote to the guest on a meeting they created
  themselves. Renders nothing when there is no note.
  """
  @spec organizer_note_box(Tokens.intent(), String.t() | nil) :: String.t()
  def organizer_note_box(intent, note),
    do: callout(intent, dgettext("emails", "Note from the organiser"), note)

  @doc """
  A quoted `message` under `heading`, tinted to match the email's `intent`.
  Renders nothing for a missing or empty message.
  """
  @spec callout(Tokens.intent(), String.t(), String.t() | nil) :: String.t()
  def callout(intent, heading, message)
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

    Stack.spaced("""
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
          #{heading}
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
    """)
  end

  def callout(intent, _heading, _message) when is_atom(intent), do: ""
end
