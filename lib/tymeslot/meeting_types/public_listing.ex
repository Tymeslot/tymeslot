defmodule Tymeslot.MeetingTypes.PublicListing do
  @moduledoc """
  Which of a host's listed meeting types a public start page offers, and in
  what order: the profile's own page at `/<username>`
  (`Tymeslot.MeetingTypes.get_public_meeting_types/1`) and each of its booking
  pages (`Tymeslot.BookingPages.list_meeting_types/1`) alike, so the two never
  drift apart.
  """

  alias Tymeslot.MeetingTypes.FixedDates
  alias Tymeslot.MeetingTypes.GroupAccess
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.MeetingTypes.OneOffEvents
  alias Tymeslot.MeetingTypes.PaymentAccess

  @doc """
  Of `meeting_types` (active ones a page lists), those the page offers, in the
  order it lists them. See `Tymeslot.MeetingTypes.get_public_meeting_types/1`
  for what is left out and why.
  """
  @spec offered([MeetingTypeSchema.t()]) :: [MeetingTypeSchema.t()]
  def offered(meeting_types) do
    meeting_types
    |> GroupAccess.reject_paused()
    |> FixedDates.reject_unbookable()
    |> PaymentAccess.reject_unsellable()
    |> OneOffEvents.order_for_listing()
  end
end
