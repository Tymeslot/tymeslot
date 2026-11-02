defmodule Tymeslot.BookingPages.BookedThrough do
  @moduledoc """
  The booking page a meeting was booked through, as the host's notifications
  name it.

  A meeting records the page in `booking_page_id`, nil for the host's own page
  at `/<username>`; deleting the page nils it, so a meeting whose page is gone
  reads as booked through none.
  """

  alias Tymeslot.BookingPages.BookingPageQueries
  alias Tymeslot.BookingPages.BookingPageSchema

  @doc """
  The page `meeting` was booked through, or nil: the loaded association when
  the caller preloaded it, else read by id.
  """
  @spec page(map()) :: BookingPageSchema.t() | nil
  def page(%{booking_page: %BookingPageSchema{} = page}), do: page

  def page(%{booking_page_id: page_id}) when is_integer(page_id),
    do: BookingPageQueries.get(page_id)

  def page(_meeting), do: nil

  @doc "The name of the page `meeting` was booked through, or nil."
  @spec name(map()) :: String.t() | nil
  def name(meeting) do
    case page(meeting) do
      %BookingPageSchema{name: name} -> name
      nil -> nil
    end
  end
end
