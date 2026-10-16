defmodule Tymeslot.Emails.Shared.PollStandings do
  @moduledoc """
  A poll's current standings as the host's emails show them: every candidate
  time in the poll's timezone with its yes / if need be / no counts, the
  leading times marked as on the dashboard (`Tymeslot.Polls.leading_slot_ids/2`),
  and how many people have voted.

  Expects the poll's `time_slots` and `participants` (with their `votes`)
  preloaded, and is called inside the host's locale.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Emails.Shared.{Formatting, Text, TimezoneHelper}
  alias Tymeslot.Polls
  alias Tymeslot.Polls.PollSchema

  @doc "The standings as MJML: a heading, one line per time and the voter count."
  @spec mjml(PollSchema.t(), String.t()) :: String.t()
  def mjml(%PollSchema{} = poll, locale) do
    """
    #{Text.section_title(dgettext("emails_polls", "Current standings"))}

    #{Text.bullet_list(lines(poll, locale))}

    #{Text.centered_text(voted(poll), padding: "0 0 12px 0")}
    """
  end

  @doc "The standings as plain text, for the text body."
  @spec text(PollSchema.t(), String.t()) :: String.t()
  def text(%PollSchema{} = poll, locale) do
    """
    #{dgettext("emails_polls", "Current standings")}:
    #{Enum.map_join(lines(poll, locale), "\n", &"- #{&1}")}
    #{voted(poll)}
    """
  end

  defp lines(poll, locale) do
    tallies = Polls.tallies(poll)
    leaders = Polls.leading_slot_ids(poll.time_slots, tallies)
    timezone = poll.timezone || "UTC"

    Enum.map(poll.time_slots, fn slot ->
      counts = Map.get(tallies, slot.id, %{})

      time =
        slot.start_time
        |> TimezoneHelper.convert_to_timezone(timezone)
        |> Formatting.format_datetime(locale)

      line =
        dgettext("emails_polls", "%{time}: %{yes} yes, %{if_need_be} if need be, %{no} no",
          time: time,
          yes: Map.get(counts, :yes, 0),
          if_need_be: Map.get(counts, :if_need_be, 0),
          no: Map.get(counts, :no, 0)
        )

      if slot.id in leaders,
        do: "★ " <> line <> " (" <> dgettext("emails_polls", "most votes") <> ")",
        else: line
    end)
  end

  defp voted(poll) do
    dngettext(
      "emails_polls",
      "%{count} person has voted so far.",
      "%{count} people have voted so far.",
      Enum.count(poll.participants, & &1.voted_at)
    )
  end
end
