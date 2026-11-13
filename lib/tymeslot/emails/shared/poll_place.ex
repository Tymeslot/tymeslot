defmodule Tymeslot.Emails.Shared.PollPlace do
  @moduledoc """
  Where a poll's meeting will be held, as the emails to its participants
  state it (`Tymeslot.Polls.location/1`): the place, or for a video call
  that its link comes once a time is confirmed, since the room is only
  created then. Nothing when the poll names no place.

  Called inside the email's locale (`Gettext.with_locale/3`).
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Emails.Shared.{Sanitise, Styles, Text}
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Polls
  alias Tymeslot.Polls.PollSchema

  @doc "The place `poll` names, as one line, or nil."
  @spec line(PollSchema.t()) :: String.t() | nil
  def line(%PollSchema{} = poll) do
    case Polls.location(poll) do
      nil ->
        nil

      %{kind: :video} ->
        dgettext("emails_polls", "Video call. You get the link once a time is confirmed.")

      # A default location label ("In person") in the participant's language.
      %{kind: kind, place: place} ->
        MeetingTypes.display_location(place, kind)
    end
  end

  @doc "The place as an MJML section, or nothing."
  @spec mjml(String.t() | nil) :: String.t()
  def mjml(nil), do: ""

  def mjml(line) do
    """
    #{Text.section_title(title())}
    <mj-text font-size="16px" color="#{Styles.ink_soft()}" line-height="24px" align="center" padding="0 0 8px 0">
      #{Sanitise.sanitize_for_email(line)}
    </mj-text>
    """
  end

  @doc "The place as lines of the plain-text body, or nothing."
  @spec text(String.t() | nil) :: String.t()
  def text(nil), do: ""
  def text(line), do: "\n#{title()}: #{line}\n"

  defp title, do: dgettext("emails_polls", "Where")
end
