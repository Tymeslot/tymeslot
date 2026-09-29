defmodule Tymeslot.Integrations.Calendar.Google.CreatableEvent do
  @moduledoc """
  An event as Google returned it, made into a body `events.insert` creates
  a new event from: the series a split makes for the following occurrences
  (`Google.SeriesSplit`), and a series copied to a calendar of another
  Google account (`Google.SeriesTransfer`). Pure data.

  What Google assigns or manages itself is not copied: its identifiers
  (`id`, `iCalUID`, `recurringEventId`, `originalStartTime`), its
  bookkeeping (`etag`, `sequence`, `created`, `updated`, `htmlLink`, `kind`)
  and its people (`organizer`, `creator`, which belong to the account that
  inserts it). Everything else is kept as it is, `recurrence` included.

  A conference is copied as the join details it has (`conferenceData`
  without any `createRequest`), which `events.insert` accepts with
  `conferenceDataVersion=1` without making a new one, so the new event
  keeps the original's Meet link; `hangoutLink` is derived from it and is
  not sent. A conference with no join details yet (only a request for one)
  is left out.
  """

  # Read-only on an insert, or Google's to assign.
  @not_copied ~w(id iCalUID recurringEventId originalStartTime etag sequence created updated
                 htmlLink kind organizer creator hangoutLink privateCopy locked attendeesOmitted)

  @doc """
  The body `events.insert` creates a copy of `event` from.
  """
  @spec from_event(map()) :: map()
  def from_event(event) when is_map(event) do
    event
    |> Map.drop(@not_copied)
    |> copy_conference()
  end

  # A request for a new conference would give the copy a Meet of its own;
  # the join details the event has are copied instead, or nothing when it
  # has none yet.
  defp copy_conference(%{"conferenceData" => conference} = body) do
    copied = Map.delete(conference, "createRequest")

    if Map.has_key?(copied, "conferenceId") or Map.has_key?(copied, "entryPoints"),
      do: Map.put(body, "conferenceData", copied),
      else: Map.delete(body, "conferenceData")
  end

  defp copy_conference(body), do: body
end
